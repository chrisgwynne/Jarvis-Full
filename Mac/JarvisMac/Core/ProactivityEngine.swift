import Foundation

// MARK: - Settings

struct ProactivitySettings {
    var enabled: Bool           = true
    var newsEnabled: Bool       = true
    var breakingNewsOnly: Bool  = false
    var minimumPriority: SignalPriority = .normal
    var dailyMaxPerSource: Int  = 10
    var quietHoursEnabled: Bool = true
    /// Minutes from midnight at which quiet hours START (default 23:00 = 1380).
    var quietHoursStart: Int    = 23 * 60
    /// Minutes from midnight at which quiet hours END (default 07:00 = 420).
    var quietHoursEnd:   Int    = 7 * 60

    // Per-source enable toggles
    var calendarEnabled: Bool = true
    var todoistEnabled:  Bool = true
    var githubEnabled:   Bool = true
    var weatherEnabled:  Bool = true
    var shopifyEnabled:  Bool = true

    // Home Assistant per-signal-type toggles
    var haDoorsEnabled:         Bool = true
    var haMotionEnabled:        Bool = true
    var haSensorsEnabled:       Bool = true
    var haDeviceOfflineEnabled: Bool = true
    var haCameraAlertsEnabled:  Bool = true   // motion-triggered camera announcements
    var haDoorbellAlertsEnabled: Bool = true  // doorbell-specific urgent announcements
    var obsidianEnabled:        Bool = true
    var emailEnabled:           Bool = true

    // Android phone event toggles
    var androidEnabled:              Bool = true
    /// If false, SMS signals are silently queued in the tray (not spoken).
    var androidMuteSMS:              Bool = false
    /// If false, WhatsApp signals are silently queued in the tray (not spoken).
    var androidMuteWhatsApp:         Bool = false
    /// If false, generic app notifications are silently queued (not spoken).
    var androidSpeakNotifications:   Bool = false

    func cooldownSeconds(for source: SignalSource) -> TimeInterval {
        switch source {
        case .news:    return 300   // 5 min between news announcements
        case .system:  return 60    // 1 min
        default:       return 120   // 2 min default
        }
    }
}

// MARK: - Engine

/// Central proactivity layer.
///
/// Integrations produce `ProactivitySignal` values; this engine decides
/// whether to ignore, log, show, or speak each one — based on priority,
/// deduplication, cooldowns, quiet hours, and the current app state.
///
/// Wire callbacks:
///   `onSpeak`   — called when the engine wants Jarvis to speak something
///   `onPresent` — called with a full `ProactivityPresentation` (speak + open overlay)
@Observable
@MainActor
final class ProactivityEngine {

    // MARK: - Public state

    private(set) var pendingSignals:   [ProactivitySignal] = []
    private(set) var dismissedSignals: [ProactivitySignal] = []
    var isPaused: Bool = false

    // MARK: - Settings

    var settings = ProactivitySettings()

    // MARK: - Diagnostics (surfaced to DebugHUD / AppState)

    private(set) var lastDecision:       ProactivityDecision = .ignore
    private(set) var lastDecisionReason: String = ""
    private(set) var lastSignalTitle:    String = ""

    // MARK: - SystemBus subscriptions

    /// Token for ConversationAwaitingResponseEvent — auto-pauses proactivity while
    /// Jarvis is waiting for the user to answer a follow-up question.
    private var awaitingResponseToken: SystemBus.SubscriptionToken?
    /// Token for ConversationFollowUpResolvedEvent — resumes proactivity after follow-up clears.
    private var followUpResolvedToken: SystemBus.SubscriptionToken?

    // MARK: - Anti-noise

    /// Dedupe keys of signals already acted on this session.
    private var announcedKeys: Set<String> = []
    /// Timestamp of last spoken signal per source.
    private var lastSpokenAt: [SignalSource: Date] = [:]
    /// How many signals have been spoken today per source.
    private var dailySpokenCount: [SignalSource: Int] = [:]
    /// Date of the last daily-count reset.
    private var dailyResetDate: Date = Calendar.current.startOfDay(for: Date())
    /// Sources muted until a specific date.
    private var mutedUntil: [SignalSource: Date] = [:]

    // MARK: - Persistent notification store

    /// Injected by `JarvisController` immediately after init.
    /// Provides cross-session deduplication: the same story won't be re-spoken
    /// after an app restart, as long as it was announced within the cooldown.
    var notificationStore: ProactiveNotificationStore?

    // MARK: - Startup gate

    /// Set by `JarvisController` immediately after init.
    /// While `startupCoordinator.proactivityGated` is true, every call to
    /// `ingest()` is routed to the coordinator's `queueOrDiscard()` instead
    /// of the normal `decide()` path. After the grace period expires the
    /// coordinator calls `onDrainQueue` which re-ingests surviving signals.
    weak var startupCoordinator: StartupCoordinator?

    // MARK: - Last spoken signal (for "open that story" / "summarise that")

    private(set) var lastSpokenSignal: ProactivitySignal? = nil

    // MARK: - Latest presentation (for "show me" / "open that" / "dismiss that")

    /// The most recent `ProactivityPresentation` built for a speakNow or
    /// showOverlay decision.  Voice commands like "show me" and "open that"
    /// read from here so they work for any signal source, not just news.
    private(set) var latestPresentation: ProactivityPresentation? = nil

    // MARK: - Preferences (persisted feedback + muted categories)

    var preferences = ProactivityPreferences.load()

    // MARK: - Callbacks

    var onSpeak:   ((String) -> Void)?
    /// Called whenever the engine produces a presentation (speakNow or showOverlay).
    /// The host should open/focus the overlay and store the presentation for follow-up
    /// voice commands. Use `presentation.autoOpenOverlay` to decide whether to open
    /// the overlay immediately or just update the tray badge.
    var onPresent: ((ProactivityPresentation) -> Void)?

    // MARK: - Count

    var pendingCount: Int { pendingSignals.count }

    // MARK: - Ingest

    /// Main entry point. Call whenever a signal arrives from any integration.
    func ingest(_ signal: ProactivitySignal, appState: AppState) {
        resetDailyCountIfNeeded()

        // ── Startup gate ─────────────────────────────────────────────────────
        // While the system is still initialising (or within the post-ready
        // grace period) signals are routed to the coordinator instead.
        // Transient loading-state signals are discarded; everything else is
        // queued and re-ingested after the grace period via onDrainQueue.
        if let coord = startupCoordinator, coord.proactivityGated {
            let queued = coord.queueOrDiscard(signal)

            // Mirror to AppState so Debug HUD shows gating activity.
            appState.proactivityLastSignalTitle  = signal.title
            appState.proactivityLastDecision     = queued ? "startup_queued" : "startup_discarded"
            appState.proactivityLastReason       = "startup_gate_active"
            appState.startupQueuedSignalCount    = coord.queuedSignalCount
            appState.startupDiscardedSignalCount = coord.discardedSignalCount

            Log.app.debug("""
                [proactivity/gate] \(queued ? "queued" : "discarded", privacy: .public) \
                src=\(signal.source.rawValue, privacy: .public) \
                title=\(signal.title.prefix(50), privacy: .public)
                """)
            return
        }
        // ─────────────────────────────────────────────────────────────────────

        let decision = decide(signal: signal, appState: appState)
        let reason = _lastReason
        lastDecision       = decision
        lastDecisionReason = reason
        lastSignalTitle    = signal.title

        Log.app.info("""
            [proactivity] source=\(signal.source.rawValue, privacy: .public) \
            priority=\(signal.priority.displayName, privacy: .public) \
            decision=\(decision.rawValue, privacy: .public) \
            reason=\(reason, privacy: .public) \
            title=\(signal.title.prefix(60), privacy: .public)
            """)

        // Mirror to AppState for diagnostics.
        appState.proactivityLastSignalTitle = signal.title
        appState.proactivityLastDecision    = decision.rawValue
        appState.proactivityLastReason      = _lastReason

        switch decision {
        case .ignore, .logOnly:
            return

        case .showQuietly:
            addToPending(signal)
            appState.proactivityPendingCount = pendingSignals.count
            markSeen(signal)

        case .showOverlay:
            // Show in relevant overlay but don't interrupt with speech.
            addToPending(signal)
            appState.proactivityPendingCount = pendingSignals.count
            markSeen(signal)
            let presentation = ProactivityPresentation.make(from: signal, decision: .showOverlay)
            latestPresentation = presentation
            onPresent?(presentation)

        case .speakNow:
            // Speak + open relevant overlay immediately.
            addToPending(signal)
            appState.proactivityPendingCount = pendingSignals.count
            let presentation = ProactivityPresentation.make(from: signal, decision: .speakNow)
            latestPresentation = presentation
            onSpeak?(presentation.spokenText)
            markSpoken(signal)
            lastSpokenSignal = signal
            onPresent?(presentation)

        case .askUser:
            addToPending(signal)
            appState.proactivityPendingCount = pendingSignals.count
        }
    }

    // MARK: - User actions

    func dismiss(_ signalID: String) {
        if let idx = pendingSignals.firstIndex(where: { $0.id == signalID }) {
            let s = pendingSignals.remove(at: idx)
            dismissedSignals.insert(s, at: 0)
            if dismissedSignals.count > 100 {
                dismissedSignals = Array(dismissedSignals.prefix(100))
            }
        }
    }

    func dismissAll() {
        dismissedSignals = pendingSignals + dismissedSignals
        if dismissedSignals.count > 100 {
            dismissedSignals = Array(dismissedSignals.prefix(100))
        }
        pendingSignals.removeAll()
    }

    func mute(_ source: SignalSource, for duration: TimeInterval) {
        mutedUntil[source] = Date().addingTimeInterval(duration)
    }

    func unmute(_ source: SignalSource) {
        mutedUntil.removeValue(forKey: source)
    }

    func pause()  { isPaused = true  }
    func resume() { isPaused = false }

    // MARK: - SystemBus wiring

    /// Subscribe to conversation lifecycle events so proactivity auto-pauses
    /// while Jarvis is awaiting a follow-up answer and resumes when resolved.
    /// Call once after the engine is initialised (JarvisController bootstrap).
    func subscribeSystemBus() {
        awaitingResponseToken = SystemBus.shared.subscribe(ConversationAwaitingResponseEvent.self) { @MainActor [weak self] _ in
            self?.isPaused = true
            Log.app.info("[proactivity] auto-paused: awaiting follow-up response")
        }
        followUpResolvedToken = SystemBus.shared.subscribe(ConversationFollowUpResolvedEvent.self) { @MainActor [weak self] _ in
            self?.isPaused = false
            Log.app.info("[proactivity] auto-resumed: follow-up resolved")
        }
    }

    func unsubscribeSystemBus() {
        if let t = awaitingResponseToken { SystemBus.shared.unsubscribe(t); awaitingResponseToken = nil }
        if let t = followUpResolvedToken { SystemBus.shared.unsubscribe(t); followUpResolvedToken = nil }
    }

    // MARK: - User feedback

    /// Record a positive feedback event for the last spoken signal.
    func recordUseful() {
        guard let signal = lastSpokenSignal else { return }
        preferences.recordPositive(source: signal.source, category: signal.category)
        Log.app.info("[proactivity] feedback=useful source=\(signal.source.rawValue, privacy: .public)")
    }

    /// Record a negative feedback event — signal was not useful.
    func recordNotUseful() {
        guard let signal = lastSpokenSignal else { return }
        preferences.recordNegative(source: signal.source, category: signal.category)
        Log.app.info("[proactivity] feedback=not_useful source=\(signal.source.rawValue, privacy: .public)")
    }

    /// Suppress this signal's category indefinitely.
    func neverTellAboutThis() {
        guard let signal = lastSpokenSignal else { return }
        preferences.suppress(source: signal.source, category: signal.category)
    }

    /// Boost priority for this signal's category.
    func alwaysTellAboutThis() {
        guard let signal = lastSpokenSignal else { return }
        preferences.boost(source: signal.source, category: signal.category)
    }

    // MARK: - Decision logic

    /// Last decision reason string — set as a side-effect of `decide()`.
    private var _lastReason: String = ""

    private func decide(signal: ProactivitySignal,
                        appState: AppState) -> ProactivityDecision {

        guard settings.enabled else {
            _lastReason = "proactivity_disabled"
            return .logOnly
        }

        if isPaused {
            _lastReason = "global_pause"
            return .logOnly
        }

        // Per-source enable flags
        switch signal.source {
        case .calendar where !settings.calendarEnabled:
            _lastReason = "calendar_disabled"
            return .logOnly
        case .todoist where !settings.todoistEnabled:
            _lastReason = "todoist_disabled"
            return .logOnly
        case .github where !settings.githubEnabled:
            _lastReason = "github_disabled"
            return .logOnly
        case .news where !settings.newsEnabled:
            _lastReason = "news_disabled"
            return .logOnly
        case .shopify where !settings.shopifyEnabled:
            _lastReason = "shopify_disabled"
            return .logOnly
        case .system where !settings.weatherEnabled && signal.category.hasPrefix("weather_"):
            _lastReason = "weather_disabled"
            return .logOnly
        // Sources with per-source toggles — only reaches here if the source IS enabled
        // (the where-guarded cases above already returned .logOnly if disabled).
        case .calendar, .todoist, .github, .news, .shopify:
            break
        case .homeAssistant where signal.category == "ha_camera_motion"
                               && !settings.haCameraAlertsEnabled:
            _lastReason = "ha_camera_alerts_disabled"
            return .logOnly
        case .homeAssistant where signal.category == "ha_doorbell"
                               && !settings.haDoorbellAlertsEnabled:
            _lastReason = "ha_doorbell_alerts_disabled"
            return .logOnly
        case .obsidian where !settings.obsidianEnabled:
            _lastReason = "obsidian_disabled"
            return .logOnly
        case .email where !settings.emailEnabled:
            _lastReason = "email_disabled"
            return .logOnly
        case .android where !settings.androidEnabled:
            _lastReason = "android_disabled"
            return .logOnly
        case .android where signal.category == AndroidSignalCategory.sms
                         && settings.androidMuteSMS:
            _lastReason = "android_sms_muted"
            return .showQuietly
        case .android where signal.category == AndroidSignalCategory.whatsApp
                         && settings.androidMuteWhatsApp:
            _lastReason = "android_whatsapp_muted"
            return .showQuietly
        case .android where signal.category == AndroidSignalCategory.notification
                         && !settings.androidSpeakNotifications:
            _lastReason = "android_notifications_muted"
            return .showQuietly
        // Sources allowed through this gate (either have no toggle, or their
        // where-guarded disable cases above already returned .logOnly).
        case .homeAssistant, .email, .memory, .system, .android, .obsidian:
            break
        }

        if let muteEnd = mutedUntil[signal.source], muteEnd > Date() {
            _lastReason = "source_muted"
            return .logOnly
        }

        if signal.priority < settings.minimumPriority {
            _lastReason = "below_threshold"
            return .logOnly
        }

        if preferences.isSuppressed(source: signal.source, category: signal.category) {
            _lastReason = "user_suppressed"
            return .logOnly
        }

        // ── Persistent cross-session deduplication ────────────────────────────
        // Checked BEFORE the in-memory set so that a story announced in a
        // previous session is blocked even after restart.
        if let store = notificationStore {
            switch store.shouldAnnounce(signal) {
            case .announce:
                // First time seen — fall through to normal engine logic.
                break
            case .reannounce(let reason):
                // Material change (title/priority) — allow re-announcement.
                // Clear from in-memory set in case it was spoken this session.
                announcedKeys.remove(signal.dedupeKey)
                _lastReason = "reannounce:\(reason)"
                // Fall through — let the priority-based logic decide the presentation.
            case .suppress(let reason):
                // Already spoken within cooldown, dismissed, or not materially changed.
                // Silently ignore — do NOT re-speak or re-open the overlay.
                _lastReason = "persistent:\(reason)"
                return .ignore
            }
        }

        if announcedKeys.contains(signal.dedupeKey) {
            _lastReason = "dedupe_hit"
            return .ignore
        }

        let todayCount = dailySpokenCount[signal.source] ?? 0
        if todayCount >= settings.dailyMaxPerSource {
            _lastReason = "daily_cap"
            return .showQuietly
        }

        if let lastAt = lastSpokenAt[signal.source] {
            let cooldown = settings.cooldownSeconds(for: signal.source)
            if Date().timeIntervalSince(lastAt) < cooldown {
                _lastReason = "cooldown"
                return .showQuietly
            }
        }

        if settings.quietHoursEnabled {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let mins  = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let start = settings.quietHoursStart
            let end   = settings.quietHoursEnd
            let inQuiet: Bool = start < end
                ? (mins >= start && mins < end)
                : (mins >= start || mins < end)
            if inQuiet && signal.priority < .urgent {
                _lastReason = "quiet_hours"
                return .showQuietly
            }
        }

        // Don't interrupt active speech/listening unless urgent+.
        if (appState.isListening || appState.isSpeaking) && signal.priority < .urgent {
            _lastReason = "jarvis_busy"
            return .showQuietly
        }

        switch signal.priority {
        case .critical:
            _lastReason = "critical_priority"
            return .speakNow
        case .urgent:
            _lastReason = "urgent_priority"
            return .speakNow
        case .high:
            _lastReason = "high_priority"
            return signal.spokenText != nil ? .speakNow : .showOverlay
        case .normal:
            _lastReason = "normal_priority"
            return .showQuietly
        case .low:
            _lastReason = "low_priority"
            return .logOnly
        }
    }

    // MARK: - Helpers

    private func addToPending(_ signal: ProactivitySignal) {
        guard !pendingSignals.contains(where: { $0.dedupeKey == signal.dedupeKey }) else { return }
        pendingSignals.insert(signal, at: 0)
        if pendingSignals.count > 50 {
            pendingSignals = Array(pendingSignals.prefix(50))
        }
    }

    private func markSpoken(_ signal: ProactivitySignal) {
        announcedKeys.insert(signal.dedupeKey)
        // Cap at 2000 entries — prevents unbounded memory growth in long-running sessions.
        // Evict the oldest 500 entries (arbitrary but stable) when the limit is hit.
        if announcedKeys.count > 2000 {
            announcedKeys = Set(announcedKeys.dropFirst(500))
        }
        lastSpokenAt[signal.source] = Date()
        dailySpokenCount[signal.source] = (dailySpokenCount[signal.source] ?? 0) + 1
        // Persist so the same story is blocked on the next app launch.
        notificationStore?.record(signal, wasSpoken: true)
        // Telemetry — source + priority only (NO body, NO spoken text).
        JarvisTelemetry.shared.record(.proactivityAlertEmitted, [
            "source":   signal.source.rawValue,
            "priority": String(describing: signal.priority),
            "category": signal.category,
        ])
    }

    /// Record that a signal was seen (added to the pending tray) without TTS.
    /// This prevents a "seen-not-spoken" record from letting a low-priority
    /// signal endlessly re-enter the tray across sessions.
    private func markSeen(_ signal: ProactivitySignal) {
        notificationStore?.record(signal, wasSpoken: false)
    }

    private func resetDailyCountIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if today > dailyResetDate {
            dailySpokenCount.removeAll()
            dailyResetDate = today
        }
    }
}
