import Foundation

// MARK: - PiperTTSBackend

/// TTSBackend wrapper around the existing PiperTTS (Jarvis ONNX voice).
/// This is the primary production backend and the first fallback in the router.
final class PiperTTSBackend: TTSBackend, @unchecked Sendable {

    // MARK: TTSBackend identity

    let id          = "piper_onnx"
    let displayName = "Jarvis ONNX (Piper)"
    let supportsStreaming       = false
    let supportsExpressionTags  = false

    // MARK: Inner Piper instance

    /// The wrapped PiperTTS. Publicly readable so JarvisController can
    /// still access it for path configuration and diagnostics.
    let piper: PiperTTS

    init(piper: PiperTTS) { self.piper = piper }

    // MARK: TTSBackend availability

    var isAvailable: Bool {
        !piper.resolvedExecutablePath.isEmpty &&
        !piper.resolvedModelPath.isEmpty
    }

    // MARK: TextToSpeaking forwarding

    var isSpeaking:       Bool             { piper.isSpeaking }
    var isSpeakingStream: AsyncStream<Bool> { piper.isSpeakingStream }

    func speak(_ text: String) {
        piper.speak(TTSTagStripper.prepare(text, for: self))
    }

    func stop() { piper.stop() }

    // MARK: TTSBackend extra

    func preload() async {
        // Piper synthesises on-demand; no preload step needed.
    }

    var diagnostics: TTSBackendDiagnostics {
        var extra: [String: String] = [
            "execPath":  piper.resolvedExecutablePath.isEmpty
                            ? "(not set)" : piper.resolvedExecutablePath,
            "modelPath": piper.resolvedModelPath.isEmpty
                            ? "(not set)" : piper.resolvedModelPath,
            "exitCode":  "\(piper.lastExitCode)",
            "synthMs":   "\(piper.lastSynthesisMs)",
        ]
        if !piper.lastStderr.isEmpty {
            extra["lastStderr"] = String(piper.lastStderr.prefix(200))
        }
        return TTSBackendDiagnostics(
            isAvailable:       isAvailable,
            unavailableReason: isAvailable ? nil :
                "Piper executable or model path is not configured. " +
                "Set paths in Settings → Voice → Piper.",
            lastError:      piper.lastError,
            lastSynthesisMs: piper.lastSynthesisMs,
            lastTextLength:  0,
            extraInfo:       extra
        )
    }
}
