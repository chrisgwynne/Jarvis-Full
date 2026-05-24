import Foundation
import AVFoundation

#if canImport(whisper)
import whisper
#endif

/// Fully-offline recognizer backed by whisper.cpp. Capture buffers from
/// AVAudioEngine, accumulate them into a single utterance window, and
/// flush to `whisper_full` when speech ends (simple energy-based VAD).
///
/// Build setup:
///   - Add the whisper.cpp Swift package
///     (`https://github.com/ggerganov/whisper.cpp`) to the Xcode project.
///   - Drop a GGML/GGUF model file (e.g. `ggml-base.en.bin`) somewhere
///     readable and set its path in Settings → Speech engine. The recognizer
///     fails-soft (throws `.notConfigured`) when the model isn't available.
///
/// When the `whisper` module isn't importable, the class compiles as a
/// no-op stub that always throws `.notConfigured` — `JarvisController`
/// then falls back to `AppleSpeechRecognizer`.
final class WhisperSpeechRecognizer: SpeechRecognizing {

    let engine: SpeechEngine = .whisper
    var isOffline: Bool { true }
    private(set) var isRunning: Bool = false

    private let modelPath: String?
    private let engineCore = AVAudioEngine()
    private var continuation: AsyncStream<Transcript>.Continuation?
    /// Buffer + voiced-marker state are touched from three threads: the
    /// audio I/O thread (ingest), the silence-polling timer's queue, and
    /// main (start/stop). Guard with one lock — the inference call runs
    /// outside the lock so it doesn't block ingest.
    private let stateLock = NSLock()
    private var samples: [Float] = []
    private let sampleRate: Double = 16_000
    private let utteranceMaxSeconds: Double = 30
    private var lastVoicedAt: Date?
    private let silenceCutoffSeconds: Double = 1.2
    private let energyThreshold: Float = 0.012
    private var flushTimer: DispatchSourceTimer?

#if canImport(whisper)
    private var ctx: OpaquePointer?
#endif

    init(modelPath: String?) {
        self.modelPath = modelPath
    }

    func requestAuthorization() async -> Bool {
        // No system permission specific to whisper.cpp beyond mic access,
        // which the system handles when AVAudioEngine first starts.
        true
    }

    func start(preferredDeviceUID: String?) throws -> AsyncStream<Transcript> {
        if isRunning { stop() }
        guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else {
            throw JarvisError.notConfigured("Whisper model path missing")
        }

#if canImport(whisper)
        if ctx == nil {
            ctx = modelPath.withCString { path in
                whisper_init_from_file_with_params(path, whisper_context_default_params())
            }
        }
        guard ctx != nil else {
            throw JarvisError.notConfigured("whisper_init failed for \(modelPath)")
        }
#else
        throw JarvisError.notConfigured("whisper.cpp Swift package not added — see README §Phase 2 setup")
#endif

        switch CoreAudioInputRouter.route(engine: engineCore, toUID: preferredDeviceUID) {
        case .failed(let why):           Log.audio.error("mic routing failed: \(why)")
        case .fellBackToDefault(let why): Log.audio.info("mic routing fell back: \(why)")
        case .routedTo(_, let name):     Log.audio.info("mic routed to \(name)")
        }

        let input = engineCore.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false) else {
            throw JarvisError.deviceUnavailable("Cannot build 16k mono float format")
        }
        let converter = AVAudioConverter(from: hwFormat, to: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, converter: converter, outFormat: outFormat)
        }

        engineCore.prepare()
        try engineCore.start()
        isRunning = true

        let (stream, continuation) = AsyncStream<Transcript>.makeStream()
        self.continuation = continuation

        // Periodically check silence to trigger an utterance flush.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(200),
                       repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.pollSilence() }
        timer.resume()
        flushTimer = timer

        return stream
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        flushTimer?.cancel()
        flushTimer = nil
        engineCore.inputNode.removeTap(onBus: 0)
        if engineCore.isRunning { engineCore.stop() }
        // Flush whatever we have at stop time as the final transcript.
        flush(final: true)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Ingest

    private func ingest(_ buffer: AVAudioPCMBuffer,
                        converter: AVAudioConverter?,
                        outFormat: AVAudioFormat) {
        guard let converter else { return }
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength)
                                              * sampleRate / buffer.format.sampleRate
                                              + 1)
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
        guard status != .error,
              let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(max(count, 1)))

        var shouldFlush = false
        stateLock.lock()
        if rms > energyThreshold { lastVoicedAt = Date() }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        if Double(samples.count) > sampleRate * utteranceMaxSeconds {
            shouldFlush = true
        }
        stateLock.unlock()
        if shouldFlush { flush(final: true) }
    }

    private func pollSilence() {
        stateLock.lock()
        let voicedAt = lastVoicedAt
        let hasSamples = !samples.isEmpty
        stateLock.unlock()
        guard let voicedAt, hasSamples else { return }
        if Date().timeIntervalSince(voicedAt) > silenceCutoffSeconds {
            flush(final: true)
        }
    }

    /// Detach the current buffer under the lock, then run inference outside
    /// the lock so ingest doesn't stall during whisper_full.
    private func flush(final: Bool) {
        stateLock.lock()
        guard !samples.isEmpty else { stateLock.unlock(); return }
        let payload = samples
        samples.removeAll(keepingCapacity: true)
        lastVoicedAt = nil
        stateLock.unlock()

#if canImport(whisper)
        guard let ctx else { return }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true
        params.single_segment = true
        // Keep the language C-string alive for the duration of whisper_full —
        // a temporary NSString bridge would be deallocated before the call.
        "en".withCString { langPtr in
            params.language = langPtr
            payload.withUnsafeBufferPointer { buf in
                _ = whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        let n = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        continuation?.yield(Transcript(text: trimmed, isFinal: final))
#else
        _ = payload
        _ = final
#endif
    }

    deinit {
#if canImport(whisper)
        if let ctx { whisper_free(ctx) }
#endif
    }
}
