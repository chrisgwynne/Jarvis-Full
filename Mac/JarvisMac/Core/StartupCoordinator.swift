import Foundation
import Observation

// MARK: - Startup Phase

/// Ordered phases of Jarvis startup. Each phase narrows the set of systems
/// that have been initialised. The coordinator advances through them during
/// `JarvisController.bootstrap()`.
enum StartupPhase: String, CaseIterable, Comparable {
    case launching        = "launching"
    case loadingSettings  = "loading_settings"
    case loadingAudio     = "loading_audio"
    case loadingSpeech    = "loading_speech"
    case loadingCamera    = "loading_camera"
    case loadingOverlays  = "loading_overlays"
    case loadingMemory    = "loading_memory"
    case ready            = "ready"
    case degradedReady    = "degraded_ready"

    /// Phases that mean startup is complete (gracefully or degraded).
    var isReady: Bool {
        self == .ready || self == .degradedReady
    }

    /// Short human-readable label shown in the Debug HUD.
    var displayLabel: String {
        switch self {
        case .launching:       return "Launching"
        case .loadingSettings: return "Loading settings"
        case .loadingAudio:    return "Loading audio"
        case .loadingSpeech:   return "Loading speech"
        case .loadingCamera:   return "Loading camera"
        case .loadingOverlays: return "Loading overlays"
        case .loadingMemory:   return "Loading memory"
        case .ready:           return "Ready"
        case .degradedReady:   return "Degraded ready"
        }
    }

    // Comparable so we can assert forward-only progress.
    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

// MARK: - Queued startup signal

/// A `ProactivitySignal` held back during the startup gate, tagged with
/// whether it was identified as a transient loading-state noise.
struct QueuedStartupSignal {
    let signal: ProactivitySignal
    let queuedAt: Date
    /// True = will be discarded at drain time rather than re-ingested.
    let isTransient: Bool
}

// MARK: - StartupCoordinator

/// Controls the startup lifecycle and enforces a proactivity gate until
/// the system is stable and a configurable grace period has elapsed.
///
/// **Wiring (in JarvisController.init):**
/// ```swift
/// proactivity.startupCoordinator = startupCoordinator
/// ```
///
/// **Bootstrap flow:**
/// ```swift
/// startupCoordinator.advance(to: .loadingSettings)
/// // … do settings work …
/// startupCoordinator.advance(to: .loadingAudio)
/// // … init audio …
/// startupCoordinator.markReady()   // or markDegradedReady()
/// ```
///
/// While `proactivityGated` is true, `ProactivityEngine.ingest()` routes
/// signals here instead of its normal decide() path. After the grace period
/// `onDrainQueue` is called with all non-transient, non-expired signals so
/// the engine can re-ingest them normally.
@Observable
@MainActor
final class StartupCoordinator {

    // MARK: - Public state

    private(set) var phase: StartupPhase = .launching

    /// Seconds to wait after reaching `ready` before allowing proactive speech.
    /// Defaults to 15 s. The user can tune this in Settings if desired.
    var gracePeriodSeconds: TimeInterval = 15

    private(set) var gracePeriodEndTime: Date? = nil
    private(set) var gracePeriodRemaining: TimeInterval = 0

    /// Timestamp at which the first proactive alert will be permitted.
    /// Nil until startup reaches a ready phase.
    private(set) var firstAlertAllowedAt: Date? = nil

    /// Number of signals currently sitting in the startup queue.
    private(set) var queuedSignalCount: Int = 0
    /// Cumulative count of signals silently discarded as transient noise.
    private(set) var discardedSignalCount: Int = 0

    /// Gated = startup not yet ready, OR grace period still counting down.
    var proactivityGated: Bool {
        !phase.isReady || gracePeriodRemaining > 0
    }

    var isReady: Bool { phase.isReady }

    // MARK: - Callbacks

    /// Called after the grace period with signals that survived filtering.
    /// The engine should re-ingest each one through its normal `ingest()` path.
    var onDrainQueue: (([ProactivitySignal]) -> Void)?

    /// Called each time the phase advances. Useful for diagnostics.
    var onPhaseChange: ((StartupPhase) -> Void)?

    // MARK: - Private

    private var queuedSignals: [QueuedStartupSignal] = []
    private var gracePeriodTask: Task<Void, Never>?

    // MARK: - Phase management

    /// Move to `newPhase`. Only advances — ignores backwards moves.
    func advance(to newPhase: StartupPhase) {
        guard newPhase > phase || newPhase == phase else { return }
        guard newPhase != phase else { return }
        Log.app.info("""
            [startup] \(self.phase.rawValue, privacy: .public) \
            → \(newPhase.rawValue, privacy: .public)
            """)
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    /// Call when all required systems are up. Starts the grace period.
    func markReady() {
        advance(to: .ready)
        startGracePeriod()
    }

    /// Call when startup completed but with non-critical degradation
    /// (e.g. camera denied, LLM unavailable). Still starts grace period.
    func markDegradedReady() {
        if phase < .degradedReady { advance(to: .degradedReady) }
        startGracePeriod()
    }

    // MARK: - Signal queue

    /// Called by `ProactivityEngine` when gated.
    /// Returns `true` if the signal was queued, `false` if discarded.
    @discardableResult
    func queueOrDiscard(_ signal: ProactivitySignal) -> Bool {
        let transient = Self.isTransientStartupSignal(signal)

        if transient {
            discardedSignalCount += 1
            Log.app.debug("""
                [startup] discard_transient \
                src=\(signal.source.rawValue, privacy: .public) \
                cat=\(signal.category, privacy: .public) \
                title=\(signal.title.prefix(50), privacy: .public)
                """)
            return false
        }

        // Deduplicate
        if queuedSignals.contains(where: { $0.signal.dedupeKey == signal.dedupeKey }) {
            return false
        }

        queuedSignals.append(QueuedStartupSignal(signal: signal,
                                                  queuedAt: Date(),
                                                  isTransient: false))
        queuedSignalCount = queuedSignals.count

        Log.app.info("""
            [startup] queued \
            src=\(signal.source.rawValue, privacy: .public) \
            priority=\(signal.priority.displayName, privacy: .public) \
            title=\(signal.title.prefix(50), privacy: .public)
            """)
        return true
    }

    // MARK: - Grace period

    private func startGracePeriod() {
        guard gracePeriodTask == nil || gracePeriodRemaining == 0 else { return }

        let endTime = Date().addingTimeInterval(gracePeriodSeconds)
        gracePeriodEndTime  = endTime
        firstAlertAllowedAt = endTime
        gracePeriodRemaining = gracePeriodSeconds

        Log.app.info("""
            [startup] grace_period_start \
            duration=\(self.gracePeriodSeconds, privacy: .public)s \
            first_alert=\(endTime.formatted(), privacy: .public)
            """)

        gracePeriodTask?.cancel()
        gracePeriodTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Tick at 0.5 s for a smooth UI countdown.
            while !Task.isCancelled {
                let remaining = endTime.timeIntervalSinceNow
                if remaining <= 0 { break }
                self.gracePeriodRemaining = remaining
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            self.gracePeriodRemaining = 0
            self.gracePeriodEndTime   = nil
            self.gracePeriodTask      = nil
            Log.app.info("[startup] grace_period_end — proactivity unlocked")
            self.drainStartupQueue()
        }
    }

    // MARK: - Drain

    private func drainStartupQueue() {
        let now = Date()
        var toDeliver: [ProactivitySignal] = []
        var discarded = 0

        for queued in queuedSignals {
            let sig = queued.signal

            // Already marked transient at queue time (belt+suspenders)
            if queued.isTransient { discarded += 1; continue }

            // Drop if expired
            if let exp = sig.expiresAt, exp < now { discarded += 1; continue }

            toDeliver.append(sig)
        }

        discardedSignalCount += discarded
        queuedSignals.removeAll()
        queuedSignalCount = 0

        Log.app.info("""
            [startup] drain \
            deliver=\(toDeliver.count, privacy: .public) \
            discard=\(discarded, privacy: .public)
            """)

        if !toDeliver.isEmpty {
            onDrainQueue?(toDeliver)
        }
    }

    // MARK: - Transient startup signal detection

    /// Returns `true` for signals about device/service loading states that are
    /// expected to resolve by the time startup finishes. These are silently
    /// discarded — never queued.
    ///
    /// Detection is keyword-based on title + body + category so it works
    /// regardless of where in the codebase the signal was created.
    static func isTransientStartupSignal(_ signal: ProactivitySignal) -> Bool {
        // Only system/memory signals can be transient startup noise;
        // news/email/calendar signals are real user-data events.
        guard signal.source == .system || signal.source == .memory else {
            return false
        }

        // Explicitly tagged categories are an O(1) fast path.
        if transientCategories.contains(signal.category.lowercased()) {
            return true
        }

        let combined = "\(signal.title) \(signal.body) \(signal.category)".lowercased()

        return transientKeywords.contains { combined.contains($0) }
    }

    // MARK: - Keyword tables

    /// Categories that signal transient startup states explicitly.
    static let transientCategories: Set<String> = [
        "startup_transient",
        "device_loading",
        "mic_loading",
        "camera_loading",
        "tts_loading",
        "stt_loading",
        "llm_checking",
        "overlay_loading",
        "memory_loading",
        "wake_word_loading",
        "audio_route_loading",
    ]

    /// Keywords that identify a signal as a transient loading-state warning.
    /// Kept in lowercase; matched with `contains()`.
    static let transientKeywords: [String] = [
        // Loading / init states
        "loading", "initializ", "starting up", "warming up",
        "checking", "connecting", "waiting for",
        // Device-specific loading phrases
        "microphone loading", "mic loading", "mic not ready",
        "speaker not ready", "audio not ready", "audio loading",
        "camera loading", "camera not ready", "camera unavailable",
        "camera initializ",
        // STT / wake word
        "wake word not started", "wake word loading", "wake word initializ",
        "speech not ready", "stt loading", "stt not ready",
        "recognizer loading",
        // TTS
        "tts loading", "tts not ready", "tts initializ",
        // LLM
        "llm checking", "llm provider check", "provider unavailable",
        "provider loading", "llm loading",
        // Overlays / web
        "webview loading", "overlay loading", "overlay not ready",
        // Memory
        "memory loading", "memory not loaded", "database loading",
        // Generic transient
        "not yet ready", "still loading", "unavailable — loading",
        // DeviceStatus.unavailable strings set during bootstrap
        "no input devices",      // set before mic enumeration
        "no camera connected",   // set before camera enumeration
        "model not configured",  // whisper not set
    ]
}
