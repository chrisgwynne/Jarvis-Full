import Foundation
import Observation

// MARK: - News overlay mode

/// Two-way switch for the news overlay layout:
///   * `.headlines` — text feed: search, label filters, clickable stories.
///   * `.watch`     — live video player + channel selector only.  No
///                    headline feed underneath; TV audio is not transcribed.
enum NewsOverlayMode: String, Equatable, Sendable {
    case headlines
    case watch
}

// MARK: - MediaPlaybackState

/// Drives the listening-pause rule.  When media is playing the active STT
/// stops so the user's wake word isn't drowned out by TV audio (and so
/// the news anchor's words aren't mistakenly transcribed as commands).
/// The wake word stays armed in `passive` mode regardless.
enum MediaPlaybackState: Equatable, Sendable {
    case inactive
    case playing(channel: String)
    case paused(channel: String)
    case stopped

    var isPlaying: Bool { if case .playing = self { return true }; return false }
    var displayLabel: String {
        switch self {
        case .inactive:              return "inactive"
        case .playing(let ch):       return "playing(\(ch))"
        case .paused(let ch):        return "paused(\(ch))"
        case .stopped:               return "stopped"
        }
    }
}

/// Global, observable app state. All UI reads from here. All services
/// write here on the main actor.
@Observable
@MainActor
final class AppState {
    // Permission / device readiness
    var microphoneStatus: DeviceStatus = .unknown
    var speechStatus: DeviceStatus = .unknown
    var cameraStatus: DeviceStatus = .unknown
    var androidServerStatus: DeviceStatus = .unknown
    var wakeWordStatus: DeviceStatus = .unknown
    var homeAssistantStatus: DeviceStatus = .unknown
    var whisperStatus: DeviceStatus = .unknown

    // Assistant lifecycle
    var phase: AssistantPhase = .idle
    var isListening: Bool = false
    var isSpeaking: Bool = false
    var isWakeArmed: Bool = false
    var lastBargeInReason: String? = nil
    // Always-on listening lifecycle
    var listeningEnabled: Bool = true       // false = muted (user said "stop listening")
    var wakeWatchdogRestarts: Int = 0       // count of watchdog-triggered wake restarts
    var lastWatchdogReason: String = ""     // last watchdog kick reason
    var lastWatchdogRecoveryAt: Date? = nil // when the watchdog last performed a restart
    var keepAwakeEnabled: Bool = true       // App Nap suppression while listening

    // Extended listening lifecycle diagnostics
    var lastPauseReason: String = ""        // reason the last temporary pause occurred
    var lastResumeReason: String = ""       // reason the last resume-from-pause occurred
    var lastOverlayEvent: String = ""       // "opened:<kind>" or "closed:<kind>"
    var listeningDesiredMode: ListeningMode = .persistent   // desired/configured mode
    var listeningActualState: ListeningState = .idleListening // actual current state
    var listeningEventLog: [ListeningLifecycleEvent] = []   // rolling 50-entry log

    // Natural-language pipeline diagnostics
    var lastNormalizedText: String = ""
    var parsedAction: String = ""
    var parsedTarget: String = ""
    var parsedConfidence: Double = 0

    // Listening diagnostics (shown in Debug HUD)
    var listeningReason: String = ""       // push_to_talk | wake_word | conversational_followup
    var lastStopReason: String = ""        // user_cancelled | silence_timeout | empty_final | …
    var listeningSessionShortID: String = ""   // first 8 chars of active session UUID
    var listeningMinRemainingMs: Int = 0       // ms remaining of protected listen window
    var listeningSawAudioBuffer: Bool = false  // first audio buffer reached recognizer
    var micInputLevel: Float = 0              // 0.0-1.0 RMS; near-zero means no signal
    var sttInputLevel: Float = 0               // RMS from active STT session tap
    var listeningRestartCount: Int = 0         // protected-window restart count for active session

    // Article overlay (in-app web view)
    var currentArticleURL: URL? = nil
    var currentArticleTitle: String = ""
    var currentArticleSource: String = ""

    // MARK: - Home Assistant camera state

    /// Entity ID of the camera currently shown in the .haCamera overlay.
    /// Set before calling `overlayManager.open(.haCamera)` so the view can
    /// resolve the correct snapshot URL.
    var haCameraEntityID: String = ""

    /// Friendly name for the active HA camera (shown in the overlay title bar).
    var haCameraFriendlyName: String = ""

    /// Whether the HA WebSocket is currently connected.
    var haWebSocketConnected: Bool = false

    /// Most recently received HA state-change event description (diagnostics).
    var haLastEventDescription: String = ""

    /// Most recent HA camera alert description (diagnostics).
    var haLastAlertDescription: String = ""

    // News diagnostics
    var activeNewsChannelName: String = ""
    var lastClickedArticleTitle: String = ""
    var lastClickedArticleURL: String = ""

    // Transcripts
    var partialTranscript: String = ""
    var lastFinalTranscript: String = ""
    var lastSpoken: String = ""
    var lastIntent: Intent? = nil
    var commandCentreVisible: Bool = false

    // Devices
    var availableMicrophones: [AudioDeviceManager.Device] = []
    var availableCameras: [CameraManager.Device] = []
    var preferredMicrophoneUID: String? = nil
    var preferredCameraUID: String? = nil
    var activeMicrophoneName: String? = nil
    var micRoutingStatus: DeviceStatus = .unknown

    // Speech engine
    var speechEngine: SpeechEngine = .apple
    var isOffline: Bool = false  // true when offline-only engines selected

    // Vision
    var lastVisionSummary: String = ""
    var lastVisionTimestamp: Date? = nil
    var motionDetected: Bool = false
    var faceCount: Int = 0
    var watchingDesk: Bool = false
    var lastCameraSummary: String = ""

    // Camera awareness (Sprint 7)
    var cameraWatchActive: Bool = false
    var lastSceneSummary: String = ""
    var lastSceneOCR: [String] = []
    var lastPresenceSummary: String = ""
    var lastSceneTimestamp: Date? = nil

    // Vision diagnostics
    var lastVisionProvider: String = ""        // "MiniMax Vision" | "Apple Vision" | ""
    var lastVisionModelUsed: String = ""       // vision model name
    var lastVisionError: String? = nil
    var lastVisionImageSizeKB: Int = 0         // size of last encoded JPEG sent to LLM
    var lastVisionCaptureMs: Int = 0           // frame capture latency
    var lastVisionEncodeMs: Int = 0            // JPEG encode latency
    var lastVisionRequestMs: Int = 0           // LLM round-trip latency
    var lastVisionTotalMs: Int = 0             // end-to-end latency
    var visionIsLoading: Bool = false          // true while a vision request is in-flight
    /// Diagnostic: which selector branch dispatched the last call ("minimax" / "gemini" / "apple").
    /// Empty until the first vision call lands.
    var lastVisionSelectorChoice: String = ""
    /// Diagnostic: when the selector deviated from the user's preferred
    /// provider (e.g. cloud consent off, fallback chain), this carries
    /// the reason code.  Nil when the user's preferred provider was used.
    var lastVisionFallbackReason: String? = nil
    /// Last structured vision observation — injected into LLM follow-up context
    /// for conversational queries like "what colour is it?" after a describe/person command.
    /// TTL = 60 seconds (see VisionContext.ttlSeconds). Cleared on next vision call.
    var lastVisionContext: VisionContext = .empty

    // Screen awareness
    var screenSummary: ScreenSummary = .empty
    var screenPermissionGranted: Bool = false
    var activeApp: String = ""
    var screenWatchActive: Bool = false

    // Memory overlay state
    var memoryRows: [MemoryRow] = []
    var memorySearchResults: [SearchResult] = []
    var recentConversations: [ConversationRow] = []
    var recentSnapshots: [SnapshotRow] = []
    var lastSearchQuery: String = ""

    // Wake word
    var lastWakeEvent: WakeWordEvent? = nil
    var recentWakeScores: [Double] = []   // bounded ring for histogram

    // Home Assistant
    var homeEntitiesCount: Int = 0
    var homeSummary: String = ""

    // Android / Networking
    var webSocketPort: UInt16 = 17872
    var connectedClients: Int = 0
    var lastAndroidContext: String = ""
    var lastAndroidTimestamp: Date? = nil
    var androidAuthRequired: Bool = false

    // Tailscale
    var tailscaleIP: String? = nil
    var tailscaleHostname: String? = nil
    var tailscaleConnected: Bool = false

    // Active phone call state (updated in real-time by AndroidEventReceiver)
    /// "ringing" | "active" | "ended" | "" (idle)
    var activeCallState: String = ""
    /// Display name of the current or most recent caller.
    var activeCallerName: String = ""
    /// When the current call transitioned to "active" — used for elapsed-time display.
    var activeCallStartTime: Date? = nil
    /// Contact ID for the active/last caller — allows precise re-dial.
    var activeCallContactId: String? = nil

    // Android phone events (mirrored from AndroidEventReceiver)
    var androidEventCount: Int = 0
    var androidEventDedupeSuppressed: Int = 0
    var lastAndroidEventType: String = ""
    var androidPermissionWarnings: [String] = []
    /// Latest caller — used for "call him back" intent.
    var latestCallerName: String = ""
    /// Latest missed caller — primary source for "call him back".
    var latestMissedCallerName: String = ""
    /// Latest SMS sender — used for "reply saying" intent.
    var latestSMSSender: String = ""
    /// Latest WhatsApp sender — used for "reply saying" intent.
    var latestWhatsAppSender: String = ""

    // Android Bridge diagnostics (mirrored from AndroidBridgeManager.diagnostics)
    var androidBridgeConnected: Bool = false
    var androidBridgeDeviceName: String = ""
    var androidBridgeBattery: Int = -1
    var androidBridgeLastHeartbeat: Date? = nil
    var androidBridgeLatencyMs: Int = -1
    var androidBridgeAuthFailures: Int = 0
    var androidBridgeTimeouts: Int = 0
    var androidBridgeCapabilities: [String] = []
    var androidBridgeLastStatus: String = ""

    // Android bridge wire-layer diagnostics (raw message tracking)
    var androidBridgeRawMessagesReceived: Int = 0
    var androidBridgeLastRawPayload: String = ""    // first 300 chars of last inbound frame
    var androidBridgeParseFailures: Int = 0
    var androidBridgeUnsupportedMessages: Int = 0
    var androidBridgeUnsolicitedEvents: Int = 0     // events NOT correlated to a pending request
    var androidBridgePhoneEventCount: Int = 0
    var androidBridgeHeartbeatCount: Int = 0
    var androidBridgePendingRequestCount: Int = 0   // live outbound requests awaiting response
    var androidBridgeLastEventRouted: String = ""   // last event type successfully routed

    // ── Remote brain routing (Phase 4 daemon bridge) ─────────────────────────
    var remoteTranscriptReceivedCount: Int = 0
    var remoteTranscriptHandledCount: Int = 0
    var remoteTranscriptRejectedCount: Int = 0
    var remoteReplySentCount: Int = 0
    var remoteBrainErrorCount: Int = 0
    var lastRemoteDevice: String = ""
    var lastRemoteTranscriptAt: Date? = nil
    var lastRemoteReplyAt: Date? = nil
    var lastRemoteRouteId: String = ""
    var lastRemoteActivityText: String = ""

    // GitHub issue overlay context — stores the most recent unknown command
    // so "log this as an issue" can pre-fill the form.
    var lastUnmatchedTranscript: String? = nil
    var lastUnmatchedContext: String?    = nil

    // Daemon state
    /// True when JarvisBrainDaemon is enabled in prefs but not reachable.
    /// Surfaced in UI to prompt the user to start the daemon.
    var daemonUnavailable: Bool = false
    /// True when the daemon is running but the Brain subsystem is degraded
    /// (e.g. database offline). Set by RuntimeCoordinator health callbacks.
    var brainDegraded: Bool = false
    /// Short reason string for the degraded state, e.g.
    /// "Brain degraded: database offline".
    var brainDegradedReason: String = ""

    // Error state
    var lastError: String? = nil

    // Performance / stability
    /// Mirrors Preferences.safeMode. Propagated in bootstrap() and
    /// whenever the toggle changes. Controls animation rates, blur effects,
    /// and WKWebView autoplay throughout the UI.
    var safeMode: Bool = true
    /// Set by SelfMonitor when it detects imminent instability and activates Safe Degraded Mode.
    var safeModeActive: Bool = false
    var safeModeReason: String = ""
    /// Set to true only when the user explicitly says "watch news" — keeps
    /// the WKWebView live player hidden on a plain "show news" command.
    var newsLivePlayerVisible: Bool = false
    /// News overlay mode.  `.headlines` is the standard headline feed
    /// (clickable stories, search, filters, refresh).  `.watch` is the
    /// dedicated live-video mode that shows ONLY the player and channel
    /// selector — no headline feed underneath.  Switched by intent:
    /// `showNews` / `summariseNews` → `.headlines`; `watchNews` /
    /// `watchNewsChannel` / `nextNewsChannel` / `prevNewsChannel` → `.watch`.
    var newsOverlayMode: NewsOverlayMode = .headlines
    /// Currently-playing media state.  Drives the listening-pause rule:
    /// while `playing`, the active STT stops, conversational follow-up
    /// is suppressed, and only the wake word remains armed — so TV audio
    /// can't be mistakenly transcribed as user commands.
    var mediaPlaybackState: MediaPlaybackState = .inactive
    /// Per-channel load-status snapshot for the watch-mode selector.
    /// Keyed by channel id; values are short strings ("loading",
    /// "playing", "blocked", "failed").  `LiveNewsPlayerView` publishes
    /// these via `JarvisController.recordNewsChannelLoadStatus(...)`.
    var newsChannelLoadStatus: [String: String] = [:]
    /// Last per-channel error message — keyed by channel id.
    var newsChannelLastError: [String: String] = [:]

    // MARK: - Reddit overlay coordination
    //
    // The Reddit overlay observes these three fields so voice intents
    // can drive it without holding a reference to the SwiftUI view.
    // JarvisController sets the value, the view reacts in onChange and
    // then writes it back to nil to consume the signal.

    /// Post id the overlay should select on next layout pass.  Set by
    /// `redditOpenIndex` / `redditQuery` after results land.
    var redditPendingSelectionPostId: String? = nil
    /// If true, the overlay should also fetch + show comments for the
    /// pending post (used by "show comments" voice intent).
    var redditAutoOpenComments: Bool = false
    /// Pending mode change (e.g. switch to a subreddit, switch to top,
    /// switch to a search result view).
    var redditPendingMode: RedditOverlayMode? = nil

    /// Last error from the Reddit subsystem — shown in Diagnostics.
    var redditLastError: String? = nil
    /// Last Reddit search query — purely for diagnostics / UI badges.
    var redditLastQuery: String? = nil
    /// Approximate count of live WKWebView instances. Used in diagnostics
    /// to detect leaks. Incremented on makeNSView, decremented on dismantleNSView.
    var webViewCount: Int = 0

    // Phrase matcher diagnostics — populated by JarvisController on each
    // phrase-store match. Shown in the debug HUD overlay.
    var phraseMatchedCommand: String? = nil
    var phraseMatchedPhrase: String? = nil
    var phraseMatchType: PhraseMatchType? = nil
    var phraseMatchConfidence: Double? = nil
    var phraseNearMisses: [MatchedCommand] = []

    // TTS diagnostics — updated by JarvisController on configure/speak
    var ttsEngine: TTSEngine = .appleSystem
    var ttsVoiceName: String = ""
    var ttsVoiceIdentifier: String = ""
    var ttsVoiceLanguage: String = ""
    var ttsLastError: String? = nil

    // Whisper STT diagnostics
    var whisperModelPath: String = ""
    var whisperModelLoaded: Bool = false
    var whisperLastError: String? = nil
    var whisperLastLatencyMs: Int = 0
    var whisperLastAudioDuration: Double = 0

    // Web overlay diagnostics
    var webOverlayBridgeMessages: Int = 0
    var webOverlayLastMessage: String = ""
    var webOverlayLastError: String? = nil

    // LLM diagnostics
    var llmProviderUsed: String = ""
    var llmModelUsed: String = ""
    var llmLatencyMs: Int = 0
    var llmLastError: String? = nil
    var llmFallbackUsed: Bool = false
    var llmParsedJSON: String = ""
    var llmValidationResult: String = ""

    // Gemini-specific diagnostics
    /// The model name as configured in Preferences at the last Gemini call.
    var geminiConfiguredModel: String = ""
    /// The model actually used (may differ from configured when 404 fallback triggered).
    var geminiResolvedModel: String = ""
    /// Whether the configured model responded successfully on the last call.
    var geminiModelAvailable: Bool = true
    /// When ListModels was last called for fallback resolution (nil = never).
    var geminiLastListModelsAt: Date? = nil
    /// Short description of the last Gemini failure, if any.
    var geminiLastFailure: String = ""

    // Summarisation diagnostics
    /// Provider ID used for the last successful summarisation (empty = none yet).
    var summarisationProvider: String = ""
    /// True when a secondary provider answered a summarisation request.
    var summarisationFallbackUsed: Bool = false
    /// Reason summarisation was skipped on the last attempt (empty = not skipped).
    var summarisationSkippedReason: String = ""

    // Safety / stability counters
    /// Number of times an unsafe-range fallback was applied (e.g. safePreview).
    var unsafeRangeFallbackCount: Int = 0
    /// Number of STT "no speech" errors that were silently ignored and restarted.
    var noSpeechIgnoredCount: Int = 0

    // Session context — wired for "repeat that", "close that", etc.
    var sessionLastSpoken: String = ""
    var sessionLastOverlayKind: OverlayKind? = nil

    // UI mode
    var uiMode: UIMode = .orb
    var debugHUDVisible: Bool = false
    var statusStripVisible: Bool = false

    // Toast notifications
    var toastMessage: String? = nil
    var toastIcon: String = "checkmark.circle.fill"

    // File search overlay (populated by JarvisController on findFile intent)
    var fileSearchResults: [MacSystemController.FileSearchResult] = []
    var fileSearchQuery: String = ""
    var fileSearchOverlayVisible: Bool = false

    // Chat overlay
    var chatMessages: [ChatMessage] = []
    var chatInputProcessing: Bool = false

    // Attention + operating mode
    var attentionState: AttentionState = .unknown
    var operatingMode: OperatingMode = .normal
    var ambientModeEnabled: Bool = false

    // Notification badge (pending count)
    var pendingNotificationCount: Int = 0

    // Proactivity diagnostics
    var proactivityLastSignalTitle: String = ""
    var proactivityLastDecision: String = ""
    var proactivityLastReason: String = ""
    var proactivityPendingCount: Int = 0
    var proactivityIsPaused: Bool = false

    // Startup readiness diagnostics
    var startupPhase: String = "launching"          // StartupPhase.rawValue
    var startupReady: Bool = false                  // true once phase is ready/degraded
    var startupGracePeriodRemaining: Double = 0     // seconds remaining in grace period
    var startupProactivityGated: Bool = true        // false once gate lifts
    var startupQueuedSignalCount: Int = 0           // signals held in startup queue
    var startupDiscardedSignalCount: Int = 0        // transient signals discarded
    var firstProactiveAlertAt: Date? = nil          // when proactivity will be unblocked

    // Conversational continuity diagnostics
    var pendingQuestion: String = ""            // question Jarvis is waiting on
    var awaitingResponseActive: Bool = false    // true while in awaitingResponse state
    var awaitingResponseType: String = ""       // yesNo | clarification | freeform
    var conversationalSessionExpiry: Date? = nil // when the 10-min armed window expires
    var lastFollowUpResolution: String = ""     // "yes→speak" | "no→speak" | "llm" | "timeout"
    var lastFollowUpTranscript: String = ""     // what the user said in the follow-up
    /// Mirrors JarvisController.conversationalArmed for the debug HUD.
    var conversationalArmedDiag: Bool = false
    /// True while persistent conversation session is active (armed + STT cycling).
    var persistentSessionActive: Bool = false
    /// How many times STT was restarted automatically in persistent-conversation mode.
    var conversationalRestarts: Int = 0

    // Widget visibility (for WidgetManager — tracks open/closed per mode)
    var openWidgets: Set<String> = []

    // Logs (bounded for the debug widget)
    private let maxLogs = 500
    var logs: [LogEntry] = []

    // Latency summaries (read-only views into LatencyTracker)
    var latencyMillis: [String: Double] = [:]

    // Command activity timeline (for UI)
    var timeline: [TimelineEvent] = []
    private let timelineLimit = 40

    func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    func log(_ category: String, _ level: LogEntry.Level, _ message: String) {
        appendLog(LogEntry(timestamp: Date(),
                           category: category,
                           level: level,
                           message: message))
    }

    func pushTimeline(_ event: TimelineEvent) {
        timeline.append(event)
        if timeline.count > timelineLimit {
            timeline.removeFirst(timeline.count - timelineLimit)
        }
    }

    /// Record a listening lifecycle transition.
    /// Called by JarvisController at every startListening / stopListening / phase change.
    /// Produces structured "[ListeningLifecycle]" entries in the main log and keeps
    /// a bounded ring in `listeningEventLog` for the diagnostics panel.
    func pushLifecycleEvent(from fromState: String, to toState: String,
                            reason: String, caller: String = #function) {
        let entry = ListeningLifecycleEvent(
            timestamp: Date(),
            fromState: fromState,
            toState: toState,
            reason: reason,
            caller: caller
        )
        listeningEventLog.append(entry)
        if listeningEventLog.count > 50 {
            listeningEventLog.removeFirst(listeningEventLog.count - 50)
        }
        log("lifecycle", .info,
            "[ListeningLifecycle] \(fromState) → \(toState) | reason=\(reason) | caller=\(caller) | desiredMode=\(listeningDesiredMode.rawValue)")
    }
}

struct TimelineEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let symbol: String      // SF Symbol name
    let title: String
    let detail: String?
}
