import AVFoundation
import Speech

/// Live transcription engine backed by Apple's Speech framework (`SFSpeechRecognizer`).
///
/// Prefers on-device recognition (unlimited duration, no network). Falls back to
/// server-based recognition with a 55-second restart cycle to stay under the
/// 1-minute per-request limit.
@MainActor
final class SpeechTranscriber: TranscriptionEngine {

    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// True when using on-device recognition (no time limit).
    private var isOnDevice = false

    /// Accumulated transcript from previous server-mode segments.
    private var accumulatedTranscript = ""

    /// Timer that restarts recognition every 55 s in server mode.
    private var restartTimer: Timer?

    private var isRunning = false

    // MARK: - TranscriptionEngine

    func start() {
        accumulatedTranscript = ""
        isOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        requestAuthorization { [weak self] in
            self?.beginRecognition()
        }
    }

    func stop() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        recognitionTask?.finish()
        recognitionTask = nil
        request?.endAudio()
        request = nil
    }

    func feedAudio(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    // MARK: - Authorization

    private func requestAuthorization(completion: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    completion()
                case .denied, .restricted:
                    self.onError?("Speech Recognition permission is required.\n\nOpen System Settings \u{2192} Privacy & Security \u{2192} Speech Recognition and enable LiveScribe.")
                case .notDetermined:
                    self.onError?("Speech Recognition authorization not determined. Please try again.")
                @unknown default:
                    self.onError?("Speech Recognition unavailable.")
                }
            }
        }
    }

    // MARK: - Recognition

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognizer is not available for the current locale.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true

        // isOnDevice starts true when supportsOnDeviceRecognition is true,
        // and gets set to false permanently if on-device fails (e.g. Siri disabled).
        if isOnDevice {
            req.requiresOnDeviceRecognition = true
        }

        request = req
        isRunning = true

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }

                if let result {
                    let segmentText = result.bestTranscription.formattedString
                    let fullText: String
                    if self.accumulatedTranscript.isEmpty {
                        fullText = segmentText
                    } else {
                        fullText = self.accumulatedTranscript + " " + segmentText
                    }
                    self.onTranscript?(fullText)
                }

                if let error {
                    let nsErr = error as NSError
                    // Ignore cancellation (216) and "no speech detected" (1110)
                    if nsErr.code == 216 || nsErr.code == 1110 { return }

                    if self.isOnDevice {
                        // On-device failed (e.g. Siri disabled) — retry in server mode
                        print("[SpeechTranscriber] On-device failed: \(error.localizedDescription). Falling back to server mode.")
                        self.isOnDevice = false
                        self.recognitionTask = nil
                        self.request = nil
                        self.beginRecognition()
                        return
                    }

                    // In server mode, a timeout/end error triggers restart
                    self.restartServerRecognition()
                }
            }
        }

        // In server mode, restart every 55 s to avoid the 1-minute limit
        if !isOnDevice {
            restartTimer?.invalidate()
            restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.restartServerRecognition()
                }
            }
        }
    }

    // MARK: - Server-mode restart

    private func restartServerRecognition() {
        guard isRunning else { return }

        // Capture current transcript before tearing down
        if let task = recognitionTask {
            // Get the latest result's text as accumulated
            // The onTranscript callback already has the full text, but we need
            // to snapshot accumulatedTranscript for the next segment
            task.finish()
        }
        request?.endAudio()

        // The accumulated transcript is whatever was last emitted.
        // We grab it from the last result via the callback — it's already
        // stored because onTranscript replaces the full text each time.
        // We need to snapshot what the user sees now as the base for the next segment.
        // Since onTranscript sets the full text, we capture it here.

        recognitionTask = nil
        request = nil
        restartTimer?.invalidate()
        restartTimer = nil

        // Small delay to let the previous task fully tear down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isRunning else { return }
            self.beginRecognition()
        }
    }

    /// Called by StatusBarController to snapshot the accumulated transcript before restart.
    func snapshotAccumulatedTranscript(_ text: String) {
        accumulatedTranscript = text
    }
}
