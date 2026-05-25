import Foundation

// MARK: - SystemTTSBackend

/// TTSBackend wrapper around AVSpeechTTS (macOS system voice).
/// Always available — used as the last-resort fallback in TTSBackendRouter.
final class SystemTTSBackend: TTSBackend, @unchecked Sendable {

    // MARK: TTSBackend identity

    let id          = "system_apple"
    let displayName = "macOS System Voice"
    let supportsStreaming       = false
    let supportsExpressionTags  = false
    let isAvailable             = true  // always present on macOS

    // MARK: Inner Apple TTS instance

    let apple: AVSpeechTTS

    init(apple: AVSpeechTTS) { self.apple = apple }

    // MARK: TextToSpeaking forwarding

    var isSpeaking:       Bool              { apple.isSpeaking }
    var isSpeakingStream: AsyncStream<Bool> { apple.isSpeakingStream }

    func speak(_ text: String) {
        apple.speak(TTSTagStripper.prepare(text, for: self))
    }

    func stop() { apple.stop() }

    // MARK: TTSBackend extra

    func preload() async {
        // Nothing to preload for AVSpeechSynthesizer.
    }

    var diagnostics: TTSBackendDiagnostics {
        let voiceName = apple.resolvedVoice?.name ?? "Default"
        return TTSBackendDiagnostics(
            isAvailable:       true,
            unavailableReason: nil,
            lastError:         nil,
            lastSynthesisMs:   0,
            lastTextLength:    0,
            extraInfo: ["voice": voiceName]
        )
    }
}
