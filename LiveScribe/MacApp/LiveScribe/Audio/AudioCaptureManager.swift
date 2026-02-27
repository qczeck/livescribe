import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Constants

private let kTargetSampleRate: Double = 16_000
private let kSourceSampleRate: Double = 48_000

// MARK: - Manager

/// Captures system audio via ScreenCaptureKit and delivers 16 kHz mono float32
/// `AVAudioPCMBuffer`s to the `onAudioBuffer` callback for the transcription engine.
@MainActor
final class AudioCaptureManager: NSObject {

    /// Called with each resampled 16 kHz mono float32 buffer.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called when capture fails (e.g. permission denied). Message is user-facing.
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: kTargetSampleRate,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Start / Stop

    func startCapture() {
        Task { await requestPermissionAndStart(isRetry: false) }
    }

    func stopCapture() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
            converter = nil
        }
    }

    // MARK: - Stream setup

    private func requestPermissionAndStart(isRetry: Bool) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                print("[AudioCaptureManager] No display found"); return
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate   = Int(kSourceSampleRate)
            config.channelCount = 2
            // Keep video at a small but valid size to avoid stream instability.
            // Very small (2×2) causes internal SCStream errors that corrupt audio buffers.
            config.width                = 32
            config.height               = 32
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

            let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try scStream.addStreamOutput(
                self, type: .audio,
                sampleHandlerQueue: .global(qos: .userInteractive)
            )
            // Register a screen handler too — without it SCStream logs
            // "stream output NOT found" for every video frame it drops internally.
            try scStream.addStreamOutput(
                self, type: .screen,
                sampleHandlerQueue: .global(qos: .background)
            )
            try await scStream.startCapture()
            stream = scStream
            print("[AudioCaptureManager] Capture started")
        } catch {
            print("[AudioCaptureManager] Failed to start: \(error)")
            let nsErr = error as NSError
            if nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsErr.code == -3801 && !isRetry {
                // TCC permission was just shown to the user. Give the system 1.5 s to
                // propagate the grant, then retry once automatically.
                print("[AudioCaptureManager] Permission pending — retrying in 1.5 s…")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await requestPermissionAndStart(isRetry: true)
            } else {
                let msg: String
                if nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsErr.code == -3801 {
                    msg = "Screen Recording permission is required.\n\nOpen System Settings → Privacy & Security → Screen Recording and enable LiveScribe, then relaunch."
                } else {
                    msg = "Audio capture failed:\n\(error.localizedDescription)"
                }
                onError?(msg)
            }
        }
    }

    // MARK: - Converter

    private func makeConverter(from desc: CMAudioFormatDescription) -> AVAudioConverter? {
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        inputFormat = fmt
        return AVAudioConverter(from: fmt, to: outputFormat)
    }

    // MARK: - Audio processing

    @MainActor
    private func process(sampleBuffer cmBuffer: CMSampleBuffer) {
        // Ensure the sample buffer's data has been fetched from the remote SCStream process.
        // Without this, copyPCMData / AudioBufferList extraction fails with -12731.
        guard CMSampleBufferDataIsReady(cmBuffer) else {
            CMSampleBufferMakeDataReady(cmBuffer)
            return  // skip this frame; next frame will be ready
        }

        if converter == nil {
            guard let desc = CMSampleBufferGetFormatDescription(cmBuffer) else { return }
            converter = makeConverter(from: desc)
        }
        guard let conv = converter, let inFmt = inputFormat else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(cmBuffer))
        guard frameCount > 0 else { return }

        // Extract audio via CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer.
        // This is more reliable than copyPCMData for SCStream buffers because it
        // correctly handles non-contiguous, non-interleaved audio buffer layouts.

        // Pass 1: find out how large the AudioBufferList structure needs to be
        // (it varies with channel count because mBuffers is a C flexible array).
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            cmBuffer, bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard ablSize > 0 else { return }

        // Pass 2: allocate and fill
        var ablStorage = [UInt8](repeating: 0, count: ablSize)
        var retainedBlock: CMBlockBuffer?
        let fillStatus = ablStorage.withUnsafeMutableBytes { raw in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                cmBuffer, bufferListSizeNeededOut: nil,
                bufferListOut: raw.bindMemory(to: AudioBufferList.self).baseAddress!,
                bufferListSize: ablSize,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &retainedBlock
            )
        }
        guard fillStatus == noErr else { return }

        // Copy into an AVAudioPCMBuffer so AVAudioConverter can consume it
        guard let inPCM = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frameCount) else { return }
        inPCM.frameLength = frameCount

        ablStorage.withUnsafeBytes { raw in
            guard let abl = raw.bindMemory(to: AudioBufferList.self).baseAddress else { return }
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            let dst = UnsafeMutableAudioBufferListPointer(inPCM.mutableAudioBufferList)
            for (s, d) in zip(src, dst) {
                guard let sp = s.mData, let dp = d.mData else { continue }
                memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
            }
        }

        // Resample + mix stereo → mono
        let ratio = kTargetSampleRate / inFmt.sampleRate
        let outCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 64
        guard let outPCM = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var inputConsumed = false
        var convError: NSError?
        conv.convert(to: outPCM, error: &convError) { _, outStatus in
            guard !inputConsumed else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inPCM
        }
        if let err = convError { print("[AudioCaptureManager] Converter error: \(err)"); return }

        if outPCM.frameLength > 0 {
            onAudioBuffer?(outPCM)
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        Task { @MainActor [weak self] in
            self?.process(sampleBuffer: sampleBuffer)
        }
    }
}
