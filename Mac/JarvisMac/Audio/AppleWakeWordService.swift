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
final class AppleWakeWordService: WakeWordDetecting, WakeWordHealthCheckable {

    private(set) var isRunning: Bool = false
    let triggers: AsyncStream<WakeWordEvent>
    private let continuation: AsyncStream<WakeWordEvent>.Continuation
    private var settings: WakeWordSettings = .default

    private var sfRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engine = AVAudioEngine()
    private var autoRestartTask: Task<Void, Never>?
    private var lastFireTime: Date = .distantPast
    private let fireCooldown: TimeInterval = 2.0

    // WakeWordHealthCheckable: timestamp of the most recent audio buffer.
    // Updated inside the AVAudioEngine tap on every buffer arrival.
    // Nil until the first buffer arrives after start().
    private(set) var lastAudioBufferTime: Date? = nil

    private let onLog: (String) -> Void
    /// Called on the main thread with the current mic RMS (0.0–1.0) roughly every buffer.
    var onAudioLevel: ((Float) -> Void)?

    // Device-disconnect observers: cleared on stop() so we don't restart
    // when the user has explicitly muted.
    private var deviceDisconnectObserver: NSObjectProtocol?
    private var deviceConnectObserver: NSObjectProtocol?

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
        // Reset cooldown so a detection right before the last stop() doesn't
        // suppress the very first detection after re-arm.
        lastFireTime = .distantPast
        // Seed lastAudioBufferTime with the current time so the health watchdog
        // doesn't immediately declare "no recent buffers" before the AVAudioEngine
        // tap has had a chance to deliver its first buffer (typically within 1–2 s).
        // A real buffer will overwrite this; if none arrives within 3 s the
        // timestamp goes stale and the watchdog correctly restarts.
        lastAudioBufferTime = Date()
        try startSession()
        isRunning = true
        AudioSessionCoordinator.shared.transition(to: .passiveWake, from: "AppleWakeWordService")
        scheduleAutoRestart()
        installDeviceObservers()
        let kws = settings.keywords.joined(separator: ", ")
        onLog("apple wake word armed, listening for: \(kws)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        autoRestartTask?.cancel()
        autoRestartTask = nil
        removeDeviceObservers()
        teardownSession()
        sfRecognizer = nil
        lastAudioBufferTime = nil
        AudioSessionCoordinator.shared.transition(to: .idle, from: "AppleWakeWordService.stop")
        onLog("apple wake word stopped")
    }

    func recordFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?) {}

    // MARK: - Session lifecycle

    private func startSession() throws {
        teardownSession()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device recognition for the wake word — avoids "Reporter
        // disconnected" errors from the Apple network STT server dropping the
        // connection, which would kill wake detection silently. On-device is
        // always available on macOS 13+ for English.
        req.requiresOnDeviceRecognition = true
        self.request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak req] buf, _ in
            req?.append(buf)
            // Health check: stamp every arriving buffer so the watchdog knows
            // audio is still flowing. This is the ONLY reliable liveness signal —
            // isRunning==true is necessary but not sufficient (engine can stall
            // silently after a device route change or App Nap throttle).
            let now = Date()
            self?.lastAudioBufferTime = now
            // Compute RMS to detect silent / disconnected mic.
            if let channelData = buf.floatChannelData?[0] {
                let frameCount = Int(buf.frameLength)
                var sumSq: Float = 0
                for i in 0 ..< frameCount { sumSq += channelData[i] * channelData[i] }
                let rms = frameCount > 0 ? sqrtf(sumSq / Float(frameCount)) : 0
                let clamped = min(rms * 10, 1.0) // scale 0-0.1 input → 0-1 display range
                DispatchQueue.main.async { self?.onAudioLevel?(clamped) }
            }
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
                        self.onLog("[WakeWord] candidateDetected keyword=\"\(kw)\" transcript=\"\(lower)\"")
                        guard now.timeIntervalSince(self.lastFireTime) > self.fireCooldown else {
                            let remaining = self.fireCooldown - now.timeIntervalSince(self.lastFireTime)
                            self.onLog("[WakeWord] rejected reason=cooldown remainingMs=\(Int(remaining * 1000))")
                            return
                        }
                        self.onLog("[WakeWord] accepted keyword=\"\(kw)\" — yielding event, releasing mic")
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
                            AudioSessionCoordinator.shared.transition(to: .idle, from: "AppleWakeWordService.wakeDetected")
                            self.onLog("[WakeWord] passive suspended — mic released for STT")
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
        // Always remove the tap before stopping. AVAudioEngine.stop() is safe
        // to call when not running; removeTap(onBus:) is a no-op when no tap
        // is installed. Doing this in a consistent order avoids double-remove.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        // Do NOT replace the engine here. Creating a new AVAudioEngine on every
        // 50-second auto-restart registers and immediately deregisters CoreAudio
        // property listeners, which produces hundreds of
        // "AudioObjectRemovePropertyListener: no object with given ID 0" (-10877)
        // log lines when the associated audio device ID becomes stale.
        // The same engine instance can be safely restarted after stop().
    }

    private func safeRestart() {
        guard isRunning else { return }
        // startSession() always calls teardownSession() at its top.
        do {
            lastAudioBufferTime = Date() // grace period — real buffer overwrites within 1–2 s
            try startSession()
        } catch {
            // Mark offline so the external watchdog can detect the failure and
            // trigger a full restart via restartWakeWordIfNeeded(). Leaving
            // isRunning==true here would hide the failure from the watchdog.
            isRunning = false
            onLog("wake word restart failed: \(error.localizedDescription)")
        }
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

    // MARK: - Device change resilience

    private func installDeviceObservers() {
        removeDeviceObservers()
        let nc = NotificationCenter.default
        // AVCaptureDevice disconnect fires when the selected mic is unplugged or
        // goes to sleep (e.g. AIRHUG Bluetooth headset powering off). We restart
        // the session so the engine picks up the new default device rather than
        // holding a stale HAL reference that delivers no buffers.
        deviceDisconnectObserver = nc.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onLog("[WakeWordHealth] input device disconnected — restarting session")
            self.lastAudioBufferTime = nil
            self.safeRestart()
        }
        deviceConnectObserver = nc.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onLog("[WakeWordHealth] input device connected — restarting session to adopt new route")
            self.lastAudioBufferTime = nil
            self.safeRestart()
        }
    }

    private func removeDeviceObservers() {
        if let o = deviceDisconnectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = deviceConnectObserver    { NotificationCenter.default.removeObserver(o) }
        deviceDisconnectObserver = nil
        deviceConnectObserver    = nil
    }
}
