import Foundation
import Speech
import AVFoundation
import os

/// Always-on wake word detection using Apple's built-in SFSpeechRecognizer.
///
/// Runs a continuous recognition session feeding microphone audio through
/// an AVAudioEngine tap. Partial transcripts are checked for the configured
/// keywords (default: "jarvis"). On match a `WakeWordEvent` is yielded and
/// the session is restarted to clear the audio buffer.
///
/// Apple limits each SFSpeechRecognitionTask to ~60 seconds; the service
/// auto-restarts every 50 seconds to stay within that limit.
///
/// Threading: `start()` and `stop()` must be called from the main thread
/// (matching JarvisController's @MainActor context). All internal session
/// management is dispatched back to the main thread to avoid races.
final class AppleWakeWordService: WakeWordDetecting {

    private(set) var isRunning: Bool = false
    let triggers: AsyncStream<WakeWordEvent>
    private let continuation: AsyncStream<WakeWordEvent>.Continuation
    private var settings: WakeWordSettings = .default

    private var sfRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var autoRestartTask: Task<Void, Never>?
    private var lastFireTime: Date = .distantPast
    private let fireCooldown: TimeInterval = 2.0

    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void = { _ in }) {
        self.onLog = onLog
        var cont: AsyncStream<WakeWordEvent>.Continuation!
        triggers = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: - WakeWordDetecting

    func configure(_ s: WakeWordSettings) throws {
        settings = s
        if isRunning { stop(); try start() }
    }

    func start() throws {
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw JarvisError.permissionDenied("Speech recognition not authorized — grant access in System Settings → Privacy")
        }
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec, rec.isAvailable else {
            throw JarvisError.deviceUnavailable("SFSpeechRecognizer not available")
        }
        sfRecognizer = rec
        try startSession()
        isRunning = true
        scheduleAutoRestart()
        let kws = settings.keywords.joined(separator: ", ")
        onLog("apple wake word armed, listening for: \(kws)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        autoRestartTask?.cancel()
        autoRestartTask = nil
        teardownSession()
        sfRecognizer = nil
        onLog("apple wake word stopped")
    }

    func recordFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?) {}

    // MARK: - Session lifecycle

    private func startSession() throws {
        teardownSession()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Allow network fallback — wake detection doesn't need to be strictly
        // offline and blocking on on-device support breaks common configurations.
        self.request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in
            req?.append(buf)
        }
        engine.prepare()
        try engine.start()

        let keywords = settings.keywords.map { $0.lowercased() }

        recognitionTask = sfRecognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.isRunning else { return }
            if let text = result?.bestTranscription.formattedString {
                let lower = text.lowercased()
                for kw in keywords {
                    if lower.contains(kw) {
                        let now = Date()
                        guard now.timeIntervalSince(self.lastFireTime) > self.fireCooldown else {
                            return
                        }
                        self.lastFireTime = now
                        let event = WakeWordEvent(timestamp: now, keyword: kw, confidence: 0.85)
                        // Tear down the wake session BEFORE yielding so the
                        // STT recognizer doesn't have to fight us for the
                        // shared mic. Subscribers (JarvisController) won't
                        // see the event until after we've fully released
                        // the audio engine on the main queue.
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.isRunning = false
                            self.autoRestartTask?.cancel()
                            self.autoRestartTask = nil
                            self.teardownSession()
                            self.sfRecognizer = nil
                            self.onLog("wake detected (mic released): \"\(kw)\"")
                            self.continuation.yield(event)
                        }
                        return
                    }
                }
            }
            // Session ended naturally (final or error) — restart to keep listening.
            if result?.isFinal == true || error != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.safeRestart()
                }
            }
        }
    }

    private func teardownSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func safeRestart() {
        guard isRunning else { return }
        teardownSession()
        do { try startSession() }
        catch { onLog("wake word restart failed: \(error.localizedDescription)") }
    }

    private func scheduleAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning else { return }
                await MainActor.run { self.safeRestart() }
            }
        }
    }
}
