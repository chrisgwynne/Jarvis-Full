import Foundation
import Speech
import AVFoundation

struct Transcript: Equatable {
    let text: String
    let isFinal: Bool
}

protocol SpeechRecognizing: AnyObject {
    func requestAuthorization() async -> Bool
    /// Some engines accept a preferred input device UID; protocol-default ignores it.
    func start(preferredDeviceUID: String?) throws -> AsyncStream<Transcript>
    func stop()
    var isRunning: Bool { get }
    /// Identifier surfaced in UI — "apple", "whisper", etc.
    var engine: SpeechEngine { get }
    /// True when the recognizer runs entirely on-device with no network.
    var isOffline: Bool { get }
}

extension SpeechRecognizing {
    func start() throws -> AsyncStream<Transcript> { try start(preferredDeviceUID: nil) }
}

/// Apple Speech framework recognizer. On macOS 14+ the framework supports
/// on-device recognition for common locales — when it does, this is
/// effectively offline. When it doesn't, Apple transparently uses a
/// network round-trip. `isOffline` reflects the actual on-device support.
final class AppleSpeechRecognizer: SpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    // Mutable so we can discard a stale engine and start fresh each session.
    // A persistent AVAudioEngine can accumulate stale HAL device references
    // after Bluetooth disconnects or route changes while stopped. When
    // prepare() is later called on such an engine, CoreAudio asserts
    // "inputNode != nullptr || outputNode != nullptr" and terminates the
    // process. Recreating the engine on every start() guarantees a clean
    // CoreAudio graph at the cost of a trivial extra allocation per session
    // (sessions happen at human cadence, not the 50-second auto-restart
    // cycle of AppleWakeWordService where engine reuse was critical).
    private var engineCore = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<Transcript>.Continuation?
    private(set) var isRunning: Bool = false
    private var sessionGeneration: Int = 0
    private var receivedAnyTranscript = false
    let engine: SpeechEngine = .apple
    var isOffline: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Fires on the audio I/O thread the first time a non-empty audio
    /// buffer reaches this recognizer. The controller uses this to mark
    /// `ListeningSession.hasReceivedAudioBuffer` and distinguish a
    /// genuine no-speech timeout from a never-armed-mic failure.
    var onFirstBuffer: (() -> Void)?

    /// Fires on the recognizer's callback thread when the underlying
    /// SFSpeechRecognitionTask hits a non-nil error. Carries the localized
    /// description so callers can decide whether to restart or surface it.
    var onTaskError: ((String) -> Void)?

    /// Called on the main thread with mic RMS (0.0–1.0) from the STT audio tap.
    var onAudioLevel: ((Float) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start(preferredDeviceUID: String?) throws -> AsyncStream<Transcript> {
        if isRunning { stop() }

        guard let recognizer, recognizer.isAvailable else {
            throw JarvisError.deviceUnavailable("Speech recognizer unavailable")
        }

        sessionGeneration += 1
        let gen = sessionGeneration

        // ── 1. Validate the preferred device UID ──────────────────────────────
        // If the UID points to a Bluetooth mic that has since disconnected,
        // passing it to CoreAudioInputRouter would fail silently and leave the
        // engine routing at an invalid device. Resolve it here; fall back to
        // the system default when it no longer resolves.
        let resolvedUID: String?
        if let uid = preferredDeviceUID {
            if CoreAudioInputRouter.audioDeviceID(forUID: uid) != nil {
                resolvedUID = uid
                Log.audio.info("[STT] preferred device UID valid uid=\(uid, privacy: .public)")
            } else {
                resolvedUID = nil
                Log.audio.warning("[STT] preferred device UID invalid/disconnected uid=\(uid, privacy: .public) — falling back to system default")
            }
        } else {
            resolvedUID = nil
        }

        // ── 2. Fresh engine per session ────────────────────────────────────────
        // Discard any previously-used engine. A stopped AVAudioEngine retains
        // stale C++ AUHAL references; calling prepare() on it after a route
        // change triggers the "inputNode != nullptr || outputNode != nullptr"
        // assertion inside CoreAudio and crashes the process.
        engineCore = AVAudioEngine()
        Log.audio.info("[STT] preparing audio engine (fresh instance)")
        AudioSessionCoordinator.shared.transition(to: .activeSTT, from: "AppleSpeechRecognizer")

        // ── 3. Validate input node before prepare() ────────────────────────────
        // outputFormat(forBus:) probes the HAL without triggering the assertion;
        // a zero sampleRate or zero channels means no valid input path exists.
        let input = engineCore.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let inputValid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
        Log.audio.info("[STT] inputNode valid=\(inputValid, privacy: .public) sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
        guard inputValid else {
            Log.audio.error("[STT] start blocked reason=no_valid_input_node sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)")
            AudioSessionCoordinator.shared.transition(to: .idle, from: "AppleSpeechRecognizer.startFailed")
            throw JarvisError.deviceUnavailable("No valid audio input — check microphone in System Settings → Privacy → Microphone")
        }

        // ── 4. Prepare, then route ─────────────────────────────────────────────
        // prepare() initialises the AUHAL before CoreAudioInputRouter calls
        // AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice).
        // Routing before prepare() returns OSStatus -10877.
        engineCore.prepare()

        var resolvedDeviceName = resolvedUID ?? "default"
        switch CoreAudioInputRouter.route(engine: engineCore, toUID: resolvedUID) {
        case .failed(let why):
            Log.audio.error("[STT] mic routing failed: \(why, privacy: .public)")
        case .fellBackToDefault(let why):
            Log.audio.info("[STT] mic routing fell back to default: \(why, privacy: .public)")
        case .routedTo(_, let name):
            Log.audio.info("[STT] mic routed to \(name, privacy: .public)")
            resolvedDeviceName = name
        }
        Log.speech.info("[STT] session started inputDevice=\(resolvedDeviceName, privacy: .public) offline=\(self.isOffline)")

        // ── 5. Recognition request ─────────────────────────────────────────────
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device recognition when available (privacy, offline).
        // If not supported, allow network fallback — blocking recognition
        // entirely is worse than a cloud round-trip. Users who require strict
        // offline should configure Whisper instead.
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        } else {
            Log.speech.warning("on-device recognition unavailable; network fallback active — switch to Whisper for strict offline")
        }
        self.request = req

        // ── 6. Install tap ─────────────────────────────────────────────────────
        // Use the format the engine resolved; the tap and req must share it.
        let tapFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        var firstBufferSeen = false
        var lastRMSLogTime: CFAbsoluteTime = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self, weak req] buffer, _ in
            req?.append(buffer)
            guard let self, self.sessionGeneration == gen else { return }
            // Fire onFirstBuffer once per session.
            if !firstBufferSeen, buffer.frameLength > 0 {
                firstBufferSeen = true
                self.onFirstBuffer?()
            }
            // RMS calculation for audio-level metering.
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sumSq: Float = 0
                for i in 0 ..< frameCount { sumSq += channelData[i] * channelData[i] }
                let rms = frameCount > 0 ? sqrtf(sumSq / Float(frameCount)) : 0
                let level = min(rms * 10, 1.0)
                DispatchQueue.main.async { self.onAudioLevel?(level) }
                // Log RMS at most once per 2 seconds to avoid flooding.
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastRMSLogTime > 2.0 {
                    lastRMSLogTime = now
                    let noAudio = level < 0.002
                    Log.speech.debug("[STT] rms=\(String(format: "%.4f", rms), privacy: .public) level=\(String(format: "%.3f", level), privacy: .public) noAudio=\(noAudio)")
                }
            }
        }

        // ── 7. Start the engine ────────────────────────────────────────────────
        do {
            try engineCore.start()
        } catch {
            // Clean up partially-built session before rethrowing.
            input.removeTap(onBus: 0)
            self.request = nil
            self.continuation = nil
            Log.audio.error("[STT] AVAudioEngine.start() failed: \(error.localizedDescription, privacy: .public)")
            AudioSessionCoordinator.shared.transition(to: .idle, from: "AppleSpeechRecognizer.engineStartFailed")
            throw error
        }
        isRunning = true
        Log.speech.info("[STT] started session=\(gen) offline=\(self.isOffline)")

        // ── 8. Recognition task ────────────────────────────────────────────────
        let (stream, cont) = AsyncStream<Transcript>.makeStream()
        self.continuation = cont

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let t = Transcript(text: result.bestTranscription.formattedString,
                                   isFinal: result.isFinal)
                if !t.text.isEmpty {
                    Log.speech.debug("[STT] partialTranscript=\(t.text.prefix(80), privacy: .public) isFinal=\(t.isFinal)")
                }
                self.continuation?.yield(t)
                if !t.text.isEmpty { self.receivedAnyTranscript = true }
                if result.isFinal {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionGeneration == gen else { return }
                        Log.speech.info("[STT] stopped reason=isFinal session=\(gen)")
                        self.stop()
                    }
                }
            }
            if let error {
                let desc = error.localizedDescription
                // Dispatch onTaskError + stop in the SAME main-queue block so
                // the controller can mark the session cancelled BEFORE stop()
                // finishes the stream and unblocks the for-await loop.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onTaskError?(desc)
                    guard self.sessionGeneration == gen else { return }
                    Log.speech.info("[STT] stopped reason=taskError session=\(gen) error=\(desc, privacy: .public)")
                    self.stop()
                }
            }
        }

        return stream
    }

    func stop() {
        guard isRunning else { return }
        if !receivedAnyTranscript {
            Log.speech.info("[STT] noSpeechDetected=true session=\(self.sessionGeneration)")
        }
        Log.speech.info("[STT] stopped reason=explicit session=\(self.sessionGeneration)")
        receivedAnyTranscript = false
        isRunning = false
        engineCore.inputNode.removeTap(onBus: 0)
        if engineCore.isRunning { engineCore.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        continuation?.finish()
        continuation = nil
        AudioSessionCoordinator.shared.transition(to: .idle, from: "AppleSpeechRecognizer.stop")
    }
}
