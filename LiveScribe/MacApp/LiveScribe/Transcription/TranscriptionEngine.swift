import AVFoundation

/// Abstraction over a live transcription backend.
/// Conformers: `SpeechTranscriber` (Speech framework), future `WhisperKitTranscriber`.
@MainActor
protocol TranscriptionEngine: AnyObject {
    /// Called with the latest cumulative transcript text.
    var onTranscript: ((String) -> Void)? { get set }
    /// Called when the engine encounters a non-recoverable error.
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()
    func feedAudio(_ buffer: AVAudioPCMBuffer)
}
