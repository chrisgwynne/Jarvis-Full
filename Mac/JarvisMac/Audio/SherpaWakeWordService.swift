import Foundation
import AVFoundation

#if canImport(sherpa_onnx)
import sherpa_onnx
#endif

/// Always-on offline keyword spotter backed by sherpa-onnx KWS.
///
/// Audio path: dedicated AVAudioEngine tap → resample to 16 kHz mono float
/// → push samples into the sherpa-onnx streaming KWS → on detection, yield
/// a `WakeWordEvent` with the matched keyword and confidence.
///
/// Compiles without sherpa-onnx (`#if canImport(sherpa_onnx)` guards every
/// C-API call); when the framework isn't linked the service still
/// initialises and exposes its protocol, but `start()` throws
/// `.notConfigured`. `JarvisController` then falls back to `NoopWakeWord`.
///
/// Setup (one-time, on a real Mac):
///
///   1. Download the macOS xcframework from sherpa-onnx releases:
///        https://github.com/k2-fsa/sherpa-onnx/releases
///      Drop `sherpa-onnx.xcframework` at `Vendor/sherpa-onnx.xcframework/`.
///      `project.yml` already references that path — re-run
///      `xcodegen generate`.
///   2. Download a KWS model archive (e.g.
///        `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01`) and
///      extract it under `Models/sherpa-kws/`. Point Settings → Wake Word
///      → Model directory at that folder.
///   3. Create a `keywords.txt` next to the model containing one line per
///      wake phrase. The default is `JARVIS` with the IPA tokens emitted
///      by sherpa-onnx's `keyword.py` helper. Point Settings → Wake Word
///      → Keywords file at that file.
final class SherpaWakeWordService: WakeWordDetecting {

    private(set) var isRunning: Bool = false
    let triggers: AsyncStream<WakeWordEvent>
    private let continuation: AsyncStream<WakeWordEvent>.Continuation
    private var settings: WakeWordSettings = .default

    private let engineCore = AVAudioEngine()
    private let workQueue = DispatchQueue(label: "com.jarvis.mac.kws", qos: .userInteractive)
    private let feedbackLog: WakeWordFeedbackLog
    private let preferredDeviceUID: () -> String?
    private let keywordsFilePath: () -> String?
    private let onLog: (String) -> Void

#if canImport(sherpa_onnx)
    private var spotter: OpaquePointer?
    private var stream: OpaquePointer?
    /// C strings handed to sherpa-onnx must outlive the spotter. We keep
    /// `strdup`'d copies here and `free()` them in `stop()` to avoid
    /// dangling pointers after `withCString` exits.
    private var pinnedStrings: [UnsafeMutablePointer<CChar>] = []
#endif

    init(feedbackLog: WakeWordFeedbackLog,
         preferredDeviceUID: @escaping () -> String?,
         keywordsFilePath: @escaping () -> String?,
         onLog: @escaping (String) -> Void) {
        self.feedbackLog = feedbackLog
        self.preferredDeviceUID = preferredDeviceUID
        self.keywordsFilePath = keywordsFilePath
        self.onLog = onLog
        var cont: AsyncStream<WakeWordEvent>.Continuation!
        self.triggers = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    // MARK: - WakeWordDetecting

    func configure(_ settings: WakeWordSettings) throws {
        self.settings = settings
        // Reconfiguring while running rebuilds the spotter so threshold and
        // keyword changes take effect immediately.
        if isRunning {
            stop()
            try start()
        }
    }

    func start() throws {
        // Idempotent: a second start would leak the previous spotter and
        // double-install the audio tap.
        if isRunning { return }
        guard settings.enabled else {
            throw JarvisError.notConfigured("Wake word disabled in settings")
        }
        guard let modelDir = settings.modelIdentifier,
              FileManager.default.fileExists(atPath: modelDir) else {
            throw JarvisError.notConfigured("Wake word model directory missing")
        }
#if !canImport(sherpa_onnx)
        throw JarvisError.notConfigured("sherpa-onnx xcframework not linked — see README §Phase 2 setup")
#else
        try buildSpotter(modelDir: modelDir)
        try startAudioTap()
        isRunning = true
        onLog("wake word armed (threshold \(settings.threshold))")
#endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engineCore.inputNode.removeTap(onBus: 0)
        if engineCore.isRunning { engineCore.stop() }
#if canImport(sherpa_onnx)
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
        stream = nil
        spotter = nil
        for ptr in pinnedStrings { free(ptr) }
        pinnedStrings.removeAll()
#endif
    }

    func recordFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?) {
        feedbackLog.append(WakeWordFeedbackEntry(feedback: feedback, event: event))
    }

    // MARK: - Audio pipeline

    private func startAudioTap() throws {
        switch CoreAudioInputRouter.route(engine: engineCore, toUID: preferredDeviceUID()) {
        case .failed(let why): onLog("wake mic routing failed: \(why)")
        default: break
        }
        let input = engineCore.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false) else {
            throw JarvisError.deviceUnavailable("Cannot build 16k mono float format")
        }
        let converter = AVAudioConverter(from: hwFormat, to: outFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.workQueue.async {
                self?.ingest(buffer, converter: converter, outFormat: outFormat)
            }
        }
        engineCore.prepare()
        try engineCore.start()
    }

    private func ingest(_ buffer: AVAudioPCMBuffer,
                        converter: AVAudioConverter?,
                        outFormat: AVAudioFormat) {
#if canImport(sherpa_onnx)
        guard let converter, let spotter, let stream else { return }
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength)
                                              * 16_000 / buffer.format.sampleRate + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: frameCapacity) else { return }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, statusOut in
            if consumed { statusOut.pointee = .endOfStream; return nil }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }
        guard status != .error, let chan = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        chan.withMemoryRebound(to: Float.self, capacity: count) { ptr in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, ptr, Int32(count))
        }
        while SherpaOnnxIsOnlineStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
        }
        if let resultPtr = SherpaOnnxGetKeywordResult(spotter, stream) {
            defer { SherpaOnnxDestroyKeywordResult(resultPtr) }
            let result = resultPtr.pointee
            if let keywordC = result.keyword {
                let keyword = String(cString: keywordC)
                if !keyword.isEmpty {
                    // Reset the stream so the same utterance doesn't refire.
                    SherpaOnnxOnlineStreamReset(spotter, stream)
                    let event = WakeWordEvent(timestamp: Date(),
                                              keyword: keyword,
                                              confidence: Double(result.score))
                    if event.confidence >= settings.threshold {
                        continuation.yield(event)
                    } else {
                        onLog("below threshold: \(keyword) @ \(event.confidence)")
                    }
                }
            }
        }
#else
        _ = buffer; _ = converter; _ = outFormat
#endif
    }

    // MARK: - sherpa-onnx wiring

#if canImport(sherpa_onnx)
    /// Allocate a heap-resident C string copy (sherpa-onnx stores the
    /// pointer; `withCString` would deallocate the buffer before
    /// `SherpaOnnxCreateKeywordSpotter` reads it).
    private func pin(_ str: String) -> UnsafeMutablePointer<CChar>? {
        guard let dup = strdup(str) else { return nil }
        pinnedStrings.append(dup)
        return dup
    }

    private func buildSpotter(modelDir: String) throws {
        // Conventional file names for the gigaspeech-3.3M KWS model. If
        // a different model variant ships with different filenames,
        // update this small table.
        let encoder = "\(modelDir)/encoder-epoch-99-avg-1-chunk-16-left-64.onnx"
        let decoder = "\(modelDir)/decoder-epoch-99-avg-1-chunk-16-left-64.onnx"
        let joiner  = "\(modelDir)/joiner-epoch-99-avg-1-chunk-16-left-64.onnx"
        let tokens  = "\(modelDir)/tokens.txt"
        // Explicit user setting wins; otherwise default to the
        // keywords.txt that ships next to the model. We deliberately do
        // NOT read UserDefaults here — preferences live in
        // PreferencesStore and are injected via `keywordsFilePath`.
        let keywordsFile = keywordsFilePath() ?? "\(modelDir)/keywords.txt"
        guard FileManager.default.fileExists(atPath: keywordsFile) else {
            for ptr in pinnedStrings { free(ptr) }
            pinnedStrings.removeAll()
            throw JarvisError.notConfigured("keywords file missing at \(keywordsFile)")
        }

        var config = SherpaOnnxKeywordSpotterConfig()
        config.model_config.transducer.encoder = pin(encoder)
        config.model_config.transducer.decoder = pin(decoder)
        config.model_config.transducer.joiner  = pin(joiner)
        config.model_config.tokens             = pin(tokens)
        config.model_config.provider           = pin("cpu")
        config.model_config.num_threads = 2
        config.model_config.debug = 0

        config.keywords_file = pin(keywordsFile)
        config.keywords_score = 1.5
        config.keywords_threshold = Float(settings.threshold)
        config.num_trailing_blanks = 1
        config.max_active_paths = 4

        guard let spotter = SherpaOnnxCreateKeywordSpotter(&config) else {
            for ptr in pinnedStrings { free(ptr) }
            pinnedStrings.removeAll()
            throw JarvisError.notConfigured("SherpaOnnxCreateKeywordSpotter returned nil")
        }
        self.spotter = spotter
        guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            for ptr in pinnedStrings { free(ptr) }
            pinnedStrings.removeAll()
            self.spotter = nil
            throw JarvisError.notConfigured("SherpaOnnxCreateKeywordStream returned nil")
        }
        self.stream = stream
    }
#endif
}
