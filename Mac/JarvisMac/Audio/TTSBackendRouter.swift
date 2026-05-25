import Foundation

// MARK: - PendingBenchmark (internal)

private struct PendingBenchmark {
    let backendId:    String
    let backendName:  String
    let textLength:   Int
    let startTime:    Date
    var firstAudioMs: Int = 0
}

// MARK: - TTSBackendRouter

/// Routes TTS calls to the best available backend and exposes a single stable
/// `isSpeakingStream` so `JarvisController.rewireSpeakingObserver` only needs
/// to wire up once — backend switches are transparent to the rest of Jarvis.
///
/// Fallback chain: preferred backend → Piper ONNX → macOS System Voice.
/// Every `speak()` call is captured in `TTSBenchmarkStore` for Voice Lab.
final class TTSBackendRouter: TextToSpeaking, @unchecked Sendable {

    // MARK: Backends

    let piperBackend:      PiperTTSBackend
    let systemBackend:     SystemTTSBackend
    let supertonicBackend: SupertonicTTSBackend

    var allBackends: [any TTSBackend] { [supertonicBackend, piperBackend, systemBackend] }

    // MARK: Active backend preference

    /// Stable ID of the user-chosen backend. Changing this triggers a proxy rewire.
    var preferredBackendId: String {
        didSet { if preferredBackendId != oldValue { rewireProxy() } }
    }

    // MARK: Stable stream (never replaced across backend switches)

    private var continuation: AsyncStream<Bool>.Continuation?
    let isSpeakingStream: AsyncStream<Bool>

    // MARK: Internal state

    private var proxyTask:      Task<Void, Never>?
    private var proxyBackendId: String?
    private var pendingBenchmark: PendingBenchmark?
    private var lastSpokenText: String = ""

    private var _isSpeaking = false
    var isSpeaking: Bool { _isSpeaking }

    // MARK: Init / deinit

    init(piper:      PiperTTSBackend,
         system:     SystemTTSBackend,
         supertonic: SupertonicTTSBackend,
         preferredBackendId: String = "piper_onnx") {
        self.piperBackend      = piper
        self.systemBackend     = system
        self.supertonicBackend = supertonic
        self.preferredBackendId = preferredBackendId
        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { cont = $0 }
        continuation = cont
    }

    deinit {
        proxyTask?.cancel()
        continuation?.finish()
    }

    // MARK: Resolved backend

    /// The backend that will receive the next `speak()` call.
    var resolvedBackend: any TTSBackend {
        if let p = allBackends.first(where: { $0.id == preferredBackendId }), p.isAvailable {
            return p
        }
        if piperBackend.isAvailable { return piperBackend }
        return systemBackend
    }

    // MARK: Bootstrap

    /// Wire the initial proxy task and Supertonic fallback hook.
    /// Call once from JarvisController bootstrap.
    func start() {
        rewireProxy()
        supertonicBackend.onSpeakFailed = { [weak self] error, text in
            guard let self else { return }
            Log.app.warning("[TTS] Supertonic failed (\(error)) — routing to Piper/System")
            let fallback: any TTSBackend = self.piperBackend.isAvailable
                ? self.piperBackend : self.systemBackend
            self.rewireProxy(to: fallback)
            fallback.speak(text)
        }
    }

    // MARK: TextToSpeaking

    func speak(_ text: String) {
        lastSpokenText = text
        let backend = resolvedBackend
        if backend.id != proxyBackendId { rewireProxy() }
        pendingBenchmark = PendingBenchmark(
            backendId:   backend.id,
            backendName: backend.displayName,
            textLength:  text.count,
            startTime:   Date()
        )
        backend.speak(text)
    }

    func stop() {
        resolvedBackend.stop()
        pendingBenchmark = nil
    }

    // MARK: Backend management

    /// Switch the active backend by stable ID. Called from Settings / Voice Lab.
    func setActiveBackend(id: String) {
        preferredBackendId = id
    }

    /// Preload all registered backends concurrently (call at startup).
    func preloadAll() async {
        await withTaskGroup(of: Void.self) { group in
            for backend in allBackends {
                group.addTask { await backend.preload() }
            }
        }
    }

    // MARK: Diagnostics

    var activeDiagnostics: TTSBackendDiagnostics { resolvedBackend.diagnostics }

    // MARK: Proxy wiring

    /// Force the proxy to watch a specific backend for one utterance (used during
    /// Supertonic → Piper fallback without changing preferredBackendId).
    private func rewireProxy(to target: any TTSBackend) {
        proxyTask?.cancel()
        proxyBackendId = target.id
        let stream     = target.isSpeakingStream
        let cont       = continuation
        proxyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var seenTrue = false
            for await val in stream {
                self._isSpeaking = val
                cont?.yield(val)
                if val { seenTrue = true }
                else if seenTrue {
                    seenTrue = false
                    // After fallback playback ends, rewire back to the resolved backend.
                    self.proxyBackendId = nil
                    self.rewireProxy()
                }
            }
        }
    }

    private func rewireProxy() {
        let target = resolvedBackend
        guard target.id != proxyBackendId else { return }
        proxyTask?.cancel()
        proxyBackendId = target.id
        let stream = target.isSpeakingStream

        proxyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var seenTrue = false
            for await val in stream {
                self._isSpeaking = val
                self.continuation?.yield(val)
                // Capture benchmark timings in-line so benchmarking never
                // blocks or delays the TTS pipeline.
                if val {
                    seenTrue = true
                    if self.pendingBenchmark != nil {
                        self.pendingBenchmark!.firstAudioMs =
                            Int(Date().timeIntervalSince(self.pendingBenchmark!.startTime) * 1000)
                    }
                } else if seenTrue {
                    if let pb = self.pendingBenchmark {
                        let totalMs = Int(Date().timeIntervalSince(pb.startTime) * 1000)
                        let synthMs = self.resolvedBackend.diagnostics.lastSynthesisMs
                        TTSBenchmarkStore.shared.add(TTSBenchmarkRecord(
                            id:              UUID(),
                            backendId:       pb.backendId,
                            backendName:     pb.backendName,
                            textLength:      pb.textLength,
                            preloadMs:       0,
                            firstAudioMs:    pb.firstAudioMs,
                            totalPlaybackMs: totalMs,
                            synthesisDoneMs: synthMs,
                            error:           nil,
                            timestamp:       pb.startTime,
                            memoryMB:        nil,
                            cpuPercent:      nil
                        ))
                        self.pendingBenchmark = nil
                    }
                    seenTrue = false
                }
            }
        }
    }
}
