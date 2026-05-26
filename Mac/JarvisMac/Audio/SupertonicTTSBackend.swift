import Foundation
import AVFoundation

// MARK: - SupertonicTTSBackend

/// Supertonic 3 neural TTS backend.
///
/// Availability is runtime-detected in two layers:
///   1. Compile-time: requires the `onnxruntime-swift-package-manager` SPM dependency.
///      Without it `isAvailable` is always false and diagnostics explain why.
///   2. Runtime: model files must be present at
///      ~/Library/Application Support/JarvisMac/TTS/Supertonic/
///      (see SupertonicModelDirectory for expected layout).
///
/// Supertonic 3 supports expression tags (<laugh>, <breath>, <sigh> …).
/// supportsExpressionTags = true so the tag stripper leaves them in the text.
///
/// On synthesis failure the backend invokes `onSpeakFailed` so the router
/// can immediately re-route the utterance to Piper / System Voice.
final class SupertonicTTSBackend: TTSBackend, @unchecked Sendable {

    // MARK: Identity

    let id                     = "supertonic"
    let displayName            = "Supertonic Neural TTS"
    let supportsStreaming       = false
    let supportsExpressionTags = true   // Supertonic 3 handles <laugh> etc. natively

    // MARK: Model directory

    let modelDirectory: SupertonicModelDirectory

    // MARK: Fallback hook (wired by TTSBackendRouter)

    /// Called on the main actor when synthesis fails, with the error message and
    /// the original text so the router can fall back to Piper/System.
    var onSpeakFailed: ((String, String) -> Void)?

    // MARK: Availability

    var isAvailable: Bool {
        #if canImport(OnnxRuntimeBindings)
        return modelDirectory.allRequiredFilesPresent
        #else
        return false
        #endif
    }

    // MARK: Async stream (stable — never replaced)

    private var continuation: AsyncStream<Bool>.Continuation?
    let isSpeakingStream: AsyncStream<Bool>
    private var _isSpeaking = false {
        didSet { if _isSpeaking != oldValue { continuation?.yield(_isSpeaking) } }
    }
    var isSpeaking: Bool { _isSpeaking }

    // MARK: Internal state

    private var synthesisTask:  Task<Void, Never>?
    private var currentPlayer:  AVAudioPlayer?
    private let synthesisQueue  = DispatchQueue(label: "com.jarvis.supertonic.synth", qos: .userInitiated)
    private let outputDir:      URL

    private(set) var lastError:       String? = nil
    private(set) var lastSynthesisMs: Int     = 0
    private(set) var lastTextLength:  Int     = 0

    #if canImport(OnnxRuntimeBindings)
    private var engine: SupertonicInferenceEngine?
    private var loadedStyle: SupertonicVoiceStyle?
    #endif

    // MARK: Init

    init(modelDirectory: SupertonicModelDirectory = .init(base: SupertonicModelDirectory.defaultURL)) {
        self.modelDirectory = modelDirectory
        self.outputDir = modelDirectory.base
            .appendingPathComponent("generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir,
                                                 withIntermediateDirectories: true)
        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: Preload

    func preload() async {
        #if canImport(OnnxRuntimeBindings)
        guard isAvailable else { return }
        do {
            let dir    = modelDirectory
            let eng    = try SupertonicInferenceEngine(directory: dir)
            guard let styleURL = dir.defaultVoiceStyleURL else {
                lastError = SupertonicError.noVoiceStyle.localizedDescription
                return
            }
            let style  = try SupertonicVoiceStyle.load(from: styleURL)
            engine      = eng
            loadedStyle = style
            lastError   = nil
            Log.app.info("[Supertonic] Engine loaded — voice: \(style.name)")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("[Supertonic] Preload failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: Load / unload

    /// Release ONNX sessions and voice style from memory.
    /// The next speak() call will lazily reload via preload().
    func unload() {
        #if canImport(OnnxRuntimeBindings)
        stop()
        engine      = nil
        loadedStyle = nil
        lastError   = nil
        Log.app.info("[Supertonic] Engine unloaded — memory released")
        #endif
    }

    // MARK: TextToSpeaking — speak

    func speak(_ text: String) {
        guard isAvailable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        synthesisTask?.cancel()
        synthesisTask = Task { [weak self] in
            await self?.runSynthesis(text: trimmed)
        }
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        currentPlayer?.stop()
        currentPlayer = nil
        if _isSpeaking {
            _isSpeaking = false
        }
    }

    // MARK: Synthesis pipeline

    private func runSynthesis(text: String) async {
        #if canImport(OnnxRuntimeBindings)
        // Lazily load engine if preload() was not called.
        if engine == nil { await preload() }

        guard !Task.isCancelled else { return }
        guard let eng = engine, let style = loadedStyle else {
            let reason = lastError ?? "Supertonic engine not loaded."
            await failWith(reason, text: text)
            return
        }

        let start = Date()
        lastTextLength = text.count

        let outputURL = outputDir.appendingPathComponent("\(UUID().uuidString).wav")
        var isCancelled = false

        do {
            let wavData = try await withCheckedThrowingContinuation { continuation in
                synthesisQueue.async {
                    do {
                        let data = try eng.synthesize(text: text,
                                                      style: style,
                                                      cancelled: { isCancelled })
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            guard !Task.isCancelled else { return }
            lastSynthesisMs = Int(Date().timeIntervalSince(start) * 1000)
            lastError       = nil

            try wavData.write(to: outputURL, options: .atomic)
            await MainActor.run { [weak self] in
                self?.playWAV(outputURL)
            }

        } catch is CancellationError {
            isCancelled = true
        } catch {
            await failWith(error.localizedDescription, text: text)
        }
        #else
        await failWith("ONNX Runtime not compiled in.", text: text)
        #endif
    }

    @MainActor
    private func playWAV(_ url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = playerDelegate
            player.prepareToPlay()
            currentPlayer = player
            _isSpeaking   = true
            player.play()
        } catch {
            lastError   = "AVAudioPlayer error: \(error.localizedDescription)"
            _isSpeaking = false
        }
    }

    @MainActor
    private func failWith(_ reason: String, text: String) {
        lastError   = reason
        _isSpeaking = false
        Log.app.error("[Supertonic] speak() failed: \(reason)")
        onSpeakFailed?(reason, text)
    }

    // MARK: AVAudioPlayer delegate (inner class to avoid NSObject inheritance)

    private lazy var playerDelegate: SupertonicPlayerDelegate = {
        SupertonicPlayerDelegate(owner: self)
    }()

    fileprivate func playerDidFinish(successfully: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.currentPlayer = nil
            self?._isSpeaking   = false
        }
    }

    fileprivate func playerDecodeError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError     = "Playback decode error: \(error.localizedDescription)"
            self?.currentPlayer = nil
            self?._isSpeaking   = false
        }
    }

    // MARK: Diagnostics

    var diagnostics: TTSBackendDiagnostics {
        let missing = modelDirectory.missingFiles()

        #if canImport(OnnxRuntimeBindings)
        let unavailableReason: String? = missing.isEmpty ? nil
            : "Missing Supertonic model files:\n"
              + missing.map { "  • \($0)" }.joined(separator: "\n")
              + "\n\nDownload from: huggingface.co/Supertone/supertonic-3"
        let extra: [String: String] = [
            "modelDir":     modelDirectory.base.path,
            "voiceStyle":   loadedStyle?.name ?? "(none loaded)",
            "engineReady":  engine != nil ? "yes" : "no",
            "missingCount": "\(missing.count)"
        ]
        #else
        let unavailableReason: String? =
            "ONNX Runtime is not compiled in. Add the onnxruntime-swift-package-manager " +
            "SPM dependency to the project, then run xcodegen generate."
        let extra: [String: String] = [
            "onnxRuntime": "not compiled in",
            "modelDir":    modelDirectory.base.path
        ]
        #endif

        return TTSBackendDiagnostics(
            isAvailable:       isAvailable,
            unavailableReason: unavailableReason ?? lastError,
            lastError:         lastError,
            lastSynthesisMs:   lastSynthesisMs,
            lastTextLength:    lastTextLength,
            extraInfo:         extra
        )
    }
}

// MARK: - SupertonicPlayerDelegate

private final class SupertonicPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private weak var owner: SupertonicTTSBackend?
    init(owner: SupertonicTTSBackend) { self.owner = owner }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        owner?.playerDidFinish(successfully: flag)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        owner?.playerDecodeError(error ?? NSError(domain: "SupertonicTTS", code: -1))
    }
}
