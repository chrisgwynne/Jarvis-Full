import Foundation

// MARK: - SupertonicTTSBackend

/// Experimental Supertonic neural TTS backend.
///
/// When compiled WITHOUT the SUPERTONIC_ENABLED flag the class still exists
/// but always reports `isAvailable = false`, so call sites can be
/// unconditional and Supertonic can be removed with a single flag change.
///
/// When enabled, model files must live at:
///   ~/Library/Application Support/JarvisMac/TTS/Supertonic/
/// Place .bin or .onnx model files there to activate the backend.
final class SupertonicTTSBackend: TTSBackend, @unchecked Sendable {

    // MARK: Identity

    let id                  = "supertonic"
    let displayName         = "Supertonic Neural TTS"
    let supportsStreaming    = false
    let supportsExpressionTags = false  // strip tags until SDK supports them

    // MARK: - Unavailable stub (non-SUPERTONIC_ENABLED builds)

#if !SUPERTONIC_ENABLED

    var isAvailable: Bool { false }

    var isSpeaking: Bool { false }

    var isSpeakingStream: AsyncStream<Bool> { AsyncStream { $0.finish() } }

    func speak(_ text: String) {}
    func stop() {}
    func preload() async {}

    var diagnostics: TTSBackendDiagnostics {
        TTSBackendDiagnostics(
            isAvailable:       false,
            unavailableReason: "Supertonic is not compiled in (SUPERTONIC_ENABLED flag not set).",
            lastError:         nil,
            lastSynthesisMs:   0,
            lastTextLength:    0,
            extraInfo:         ["buildFlag": "SUPERTONIC_ENABLED not set"]
        )
    }

#else

    // MARK: - Model path (SUPERTONIC_ENABLED builds)

    static let modelDirectory: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("JarvisMac",   isDirectory: true)
            .appendingPathComponent("TTS",         isDirectory: true)
            .appendingPathComponent("Supertonic",  isDirectory: true)
    }()

    // MARK: Availability

    var isAvailable: Bool {
        let fm = FileManager.default
        let dir = Self.modelDirectory
        guard fm.fileExists(atPath: dir.path) else { return false }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasSuffix(".bin") || $0.hasSuffix(".onnx") }
    }

    // MARK: Stream

    private var continuation: AsyncStream<Bool>.Continuation?
    let isSpeakingStream: AsyncStream<Bool>
    private var _isSpeaking = false
    var isSpeaking: Bool { _isSpeaking }

    init() {
        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: TextToSpeaking

    func speak(_ text: String) {
        guard isAvailable else { return }
        // Expression tags are stripped by TTSTagStripper in the router before
        // this point, but strip again defensively.
        _ = TTSTagStripper.prepare(text, for: self)
        // TODO: call real Supertonic SDK when integrated.
        // For now, synthesise nothing — this path is only reached in
        // SUPERTONIC_ENABLED builds, which are development-only.
        _isSpeaking = true
        continuation?.yield(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?._isSpeaking = false
            self?.continuation?.yield(false)
        }
    }

    func stop() {
        _isSpeaking = false
        continuation?.yield(false)
    }

    func preload() async {
        // Load Supertonic model weights here when SDK is available.
    }

    var diagnostics: TTSBackendDiagnostics {
        let dir   = Self.modelDirectory.path
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return TTSBackendDiagnostics(
            isAvailable:       isAvailable,
            unavailableReason: isAvailable ? nil :
                "No Supertonic model files found in \(dir). " +
                "Place .bin or .onnx files there to enable this backend.",
            lastError:         nil,
            lastSynthesisMs:   0,
            lastTextLength:    0,
            extraInfo: [
                "modelDir": dir,
                "files":    files.isEmpty ? "(none)" : files.prefix(3).joined(separator: ", ")
            ]
        )
    }

#endif
}
