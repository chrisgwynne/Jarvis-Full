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
    private let engineCore = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<Transcript>.Continuation?
    private(set) var isRunning: Bool = false
    private var sessionGeneration: Int = 0
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

        // Phase-2 routing: actually point AVAudioEngine at the chosen device.
        switch CoreAudioInputRouter.route(engine: engineCore, toUID: preferredDeviceUID) {
        case .failed(let why):
            Log.audio.error("mic routing failed: \(why)")
        case .fellBackToDefault(let why):
            Log.audio.info("mic routing fell back: \(why)")
        case .routedTo(_, let name):
            Log.audio.info("mic routed to \(name)")
        }

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

        let input = engineCore.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        var firstBufferSeen = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak req] buffer, _ in
            req?.append(buffer)
            // Fire onFirstBuffer once per session so the controller can
            // tell whether the mic is actually producing audio.
            guard let self, !firstBufferSeen,
                  self.sessionGeneration == gen,
                  buffer.frameLength > 0
            else { return }
            firstBufferSeen = true
            self.onFirstBuffer?()
        }

        engineCore.prepare()
        do {
            try engineCore.start()
        } catch {
            // Clean up partially-built session before rethrowing so a
            // subsequent start() doesn't trip the `if isRunning { stop() }`
            // guard with a dangling tap.
            input.removeTap(onBus: 0)
            self.request = nil
            self.continuation = nil
            Log.audio.error("AVAudioEngine.start() failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        isRunning = true
        Log.speech.info("STT session \(gen) started (offline=\(self.isOffline))")

        let (stream, continuation) = AsyncStream<Transcript>.makeStream()
        self.continuation = continuation

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let t = Transcript(text: result.bestTranscription.formattedString,
                                   isFinal: result.isFinal)
                self.continuation?.yield(t)
                if result.isFinal {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionGeneration == gen else { return }
                        Log.speech.info("STT session \(gen) isFinal — calling stop()")
                        self.stop()
                    }
                }
            }
            if let error {
                let desc = error.localizedDescription
                // Dispatch onTaskError + stop in the SAME main-queue block
                // so the controller can mark the session cancelled BEFORE
                // `stop()` finishes the stream and unblocks the for-await
                // loop. Otherwise the post-loop restart fires before the
                // error-handler Task runs.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onTaskError?(desc)
                    guard self.sessionGeneration == gen else { return }
                    Log.speech.info("STT session \(gen) error: \(desc, privacy: .public) — calling stop()")
                    self.stop()
                }
            }
        }

        return stream
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engineCore.inputNode.removeTap(onBus: 0)
        if engineCore.isRunning { engineCore.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        continuation?.finish()
        continuation = nil
    }
}
