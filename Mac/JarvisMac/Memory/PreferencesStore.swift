import Foundation

/// Codable user preferences persisted to
/// `~/Library/Application Support/JarvisMac/preferences.json`.
/// Easy to swap for SQLite or a shared memory DB later.
struct Preferences: Codable, Equatable {
    var userName: String?
    var preferredMicrophoneUID: String?
    var preferredCameraUID: String?
    /// UID of the secondary (desk) camera. nil = not configured.
    var deskCameraUID: String?
    var smartHomeBaseURL: String?
    var smartHomeToken: String?
    var todoistAPIToken: String?
    var githubPersonalAccessToken: String?
    var googleCalendarEnabled: Bool = true
    var androidTrustedDeviceIDs: [String]
    var webSocketPort: UInt16
    var webSocketAuthToken: String?
    var requireWebSocketAuth: Bool
    var wakeWord: WakeWordSettings
    var speechEngine: SpeechEngine
    var whisperModelPath: String?
    var sherpaModelDirectory: String?
    var sherpaKeywordsFilePath: String?
    var bargeInEnabled: Bool
    var bargeInSensitivity: Float          // 0.0–1.0 placeholder for future tuning
    var conversationalFollowUpEnabled: Bool
    var conversationalTimeoutSeconds: Double
    /// When true, Jarvis automatically restarts STT after each silence timeout
    /// so the conversational session stays alive indefinitely without requiring
    /// another wake word. Set false to revert to the old 8-second window behaviour.
    var persistentConversationEnabled: Bool = true
    var screenWatchIntervalSeconds: Double
    var cameraWatchIntervalSeconds: Double
    var uiModeRaw: String
    var statusStripVisible: Bool
    var operatingModeRaw: String
    var ambientModeEnabled: Bool

    // Performance / stability
    /// When true, disables live video autoplay, heavy blur effects, and
    /// high-frequency animations to prevent WindowServer overload.
    /// Default ON — the user must explicitly enable Enhanced mode.
    var safeMode: Bool

    // ── Emergency Safe Mode ───────────────────────────────────────────────────
    /// Master kill switch. When true, NO subsystems start at launch — only the
    /// UI window, health monitor, and crash log are active.
    /// Defaults FALSE — all subsystems enabled. Enable in Settings > Developer
    /// to disable subsystems one-by-one for crash isolation.
    var emergencySafeMode: Bool = false

    /// Per-subsystem enable flags.
    /// Only consulted when emergencySafeMode = false.
    /// All default true so toggling off emergency mode restores the previous
    /// full-mode behaviour. Set individual flags false for binary isolation:
    /// enable one subsystem at a time, run for 15 min, observe for crashes.
    var subsystemCameraEnabled: Bool = true
    var subsystemWakeWordEnabled: Bool = true
    var subsystemWebSocketEnabled: Bool = true
    var subsystemTailscaleEnabled: Bool = true
    var subsystemNewsEnabled: Bool = true
    var subsystemWeatherProviderEnabled: Bool = true
    var subsystemCalendarProviderEnabled: Bool = true
    var subsystemTodoistProviderEnabled: Bool = true
    var subsystemGitHubProviderEnabled: Bool = true
    var subsystemHAProviderEnabled: Bool = true
    var subsystemShopifyProviderEnabled: Bool = true
    var subsystemObsidianEnabled: Bool = true
    var subsystemSemanticMemoryEnabled: Bool = true
    var subsystemConversationSummariserEnabled: Bool = true

    // ── Jarvis Voice (TTS) ────────────────────────────────────────────────────
    /// Which TTS engine Jarvis uses to speak back. Separate from speechEngine
    /// (which controls how Jarvis listens). Default = Apple System Voice.
    var ttsEngine: TTSEngine = .appleSystem
    /// AVSpeechSynthesisVoice identifier (e.g. "com.apple.ttsbundle.siri_male_en-GB_compact").
    /// nil = auto-select the best available male English voice at runtime.
    var ttsVoiceIdentifier: String? = nil
    /// Speaking rate 0.0–1.0. Default 0.5 matches AVSpeechUtteranceDefaultSpeechRate.
    var ttsRate: Float = 0.5
    /// Pitch multiplier 0.5–2.0. Default 1.0 = no change.
    var ttsPitch: Float = 1.0
    /// Volume 0.0–1.0. Default 1.0 = full volume.
    var ttsVolume: Float = 1.0

    // ── Piper ONNX TTS ───────────────────────────────────────────────────────
    var piperExecutablePath: String? = nil
    var piperModelPath: String? = nil
    var piperConfigPath: String? = nil
    /// Speaker ID for multi-speaker models. nil = default speaker.
    var piperSpeakerId: Int? = nil
    /// Fall back to Apple TTS when Piper fails. Default true.
    var piperFallbackToApple: Bool = true
    /// Stable ID of the active TTS backend in TTSBackendRouter.
    /// Valid values: "piper_onnx", "system_apple", "supertonic".
    var ttsBackendId: String = "piper_onnx"

    // ── Web Overlays ─────────────────────────────────────────────────────────
    var webOverlaysEnabled: Bool = false
    var webOverlayAllowRemoteURLs: Bool = false
    var webOverlayDebugEnabled: Bool = false

    // LLM reasoning layer
    // Identity
    /// The user's name — shown in greetings and answered for "what is my name".
    /// Optional so existing installs that never set it don't get a spurious default.
    // (already defined above as userName: String?)

    /// The assistant's name — answered for "what's your name". Defaults to "Jarvis".
    var assistantName: String = "Jarvis"

    // ── Shopify ───────────────────────────────────────────────────────────────
    var shopifyAccessToken: String? = nil
    var shopifyShopDomain: String? = nil
    var shopifyLowStockThreshold: Int = 5

    // ── Spotify ──────────────────────────────────────────────────────────────
    /// Personal access token from the Spotify Web API OAuth Playground.
    /// Needs `user-read-playback-state` and `user-modify-playback-state` scopes.
    var spotifyPersonalToken: String? = nil

    // ── Obsidian ─────────────────────────────────────────────────────────────
    /// Absolute path to the Obsidian vault root directory.
    var obsidianVaultPath: String? = nil
    /// When true, relevant vault notes are injected into the LLM context (RAG).
    var obsidianLLMContextEnabled: Bool = true
    /// Maximum number of notes to inject per LLM query (1–10).
    var obsidianMaxContextNotes: Int = 3
    /// Proactivity: surface recently changed notes / watch-tag notes.
    var obsidianProactivityEnabled: Bool = true
    /// Tags that trigger proactivity alerts (e.g. ["jarvis", "review", "urgent"]).
    var obsidianWatchTags: [String] = ["jarvis", "review", "urgent"]

    // ── JarvisBrainDaemon ────────────────────────────────────────────────────
    /// When true, the app defers port 8765 to the background LaunchAgent daemon
    /// instead of hosting the server in-process.
    var daemonEnabled: Bool = true
    /// Kept for JSON backward compatibility. Always false — the Mac app no longer
    /// falls back to hosting an external WebSocket server when the daemon is absent.
    var legacyBrainServerEnabled: Bool = false
    /// When true, Mac TTS speaks the reply generated for a remote device locally.
    /// Default off — remote device handles its own TTS.
    var speakRemoteRepliesOnMac: Bool = false
    /// When true, the last remote transcript and device are shown in Mac diagnostics UI.
    var showRemoteActivityInMacUI: Bool = true
    /// When true, remote devices may trigger any intent the Mac would handle locally.
    var allowRemoteDevicesToTriggerTools: Bool = true
    /// When true, remote devices may trigger Home Assistant device control.
    /// Off by default for safety.
    var allowRemoteDevicesToTriggerHomeAssistant: Bool = false

    // ── Mac Brain HTTP server ────────────────────────────────────────────────
    /// Master enable for the local HTTP Brain API used by Android Jarvis.
    var brainServerEnabled: Bool = false
    /// TCP port for the Brain HTTP server. Default 8765.
    var brainServerPort: UInt16 = 8765
    /// When true, the server binds only to 127.0.0.1 (loopback).
    /// Set false to allow connections from the local network / Tailscale.
    var brainServerBindLocalOnly: Bool = false

    // ── Distributed Brain / Windows Sidecar ─────────────────────────────────
    /// Kept for JSON backward compatibility. Never used to activate bridging —
    /// JarvisBrainDaemon owns all cross-device WebSocket hosting.
    var distributedBrainEnabled: Bool = false

    // ── Mac Brain Gateway (unified port 8765) ────────────────────────────────
    /// When true, the legacy Android WebSocket server on port 17872 stays active
    /// for backward compatibility with older Android installs that have not updated.
    /// New installs default to false — Android uses /v1/android/ws on port 8765.
    var legacyAndroidPortEnabled: Bool = false

    // ── Mac Camera HTTP server ───────────────────────────────────────────────
    var cameraServerEnabled: Bool = false
    var cameraServerRequireToken: Bool = true
    var keepCameraWarm: Bool = false
    var cameraFPS: Int = 5
    var cameraJPEGQuality: String = "medium"

    // ── Local LLM learning engine ────────────────────────────────────────────
    var localLLMEnabled: Bool = false
    var localLLMProvider: String = "openai_compatible"
    var localLLMBaseURL: String = "http://localhost:1234"
    var localLLMModelName: String = ""
    var localLLMApiKey: String? = nil
    var localLLMTimeoutSecs: Int = 30
    var localLLMMaxTokens: Int = 256
    var localLLMTemperature: Double = 0.2

    // ── Conversational Jarvis ────────────────────────────────────────────────
    /// Enable dual-lane routing: route PROJECT_REFLECTION/GENERAL_CHAT/MEMORY_UPDATE
    /// through the conversational handler before the command pipeline.
    var conversationalModeEnabled: Bool = true
    /// How long (seconds) to wait before flushing a conversation session summary
    /// to Obsidian/memory. 0 = immediate.
    var conversationalSessionFlushDelay: Double = 5.0
    /// Save raw transcripts per session (for debugging / privacy audit).
    var conversationalSaveRawTranscripts: Bool = false
    /// Write daily summaries to Obsidian vault.
    var conversationalDailyNotesEnabled: Bool = true
    /// Path to the project documentation folder (e.g. /Users/chris/Desktop/jarvis).
    /// Jarvis will read FEATURES.md, TODO.md, CLAUDE.md from this folder.
    var projectDocsPath: String? = nil
    /// Whether project knowledge is queried for PROJECT_REFLECTION utterances.
    var projectKnowledgeEnabled: Bool = true
    /// Memory auto-save mode for conversational turns.
    /// "off" / "ask" / "auto_project" / "auto_all"
    var conversationalMemoryAutoSave: String = "auto_project"
    /// Show route classification and retrieval diagnostics in debug HUD.
    var conversationalDiagnosticsEnabled: Bool = false
    /// Enable codebase indexing for self-knowledge queries.
    var codebaseIndexEnabled: Bool = true
    /// Override path for codebase index root (nil = project root from CLAUDE.md path).
    var codebaseIndexPath: String? = nil
    /// Execute detected commands silently without spoken confirmation.
    var silentActionsEnabled: Bool = true
    /// Allow self-knowledge queries to use ProjectKnowledgeGraph + CodebaseIndexer.
    var selfKnowledgeEnabled: Bool = true

    // ── Home Assistant Camera Alerts ─────────────────────────────────────────
    /// Whether motion-triggered camera alerts are announced.
    var haCameraAlertsEnabled: Bool = true
    /// Whether doorbell-specific events get a distinct urgent announcement.
    var haDoorbellAlertsEnabled: Bool = true
    /// Minimum seconds between alerts for a single motion sensor.
    var haMotionCooldownSeconds: Double = 120
    /// Minimum seconds between ANY camera alert (global throttle).
    var haGlobalAlertCooldownSeconds: Double = 20
    /// Motion-sensor-to-camera mappings, persisted via PreferencesStore.
    var haMotionCameraMappings: [HAMotionCameraMapping] = []
    /// Override phrase for doorbell events (used by ProactivityEngine).
    var haDoorbellPhrase: String = "Someone's at the door."

    // ── Hand Tracking / Gestures ─────────────────────────────────────────────
    /// Master enable for hand tracking spatial layer.
    var handTrackingEnabled: Bool = true
    /// User's dominant hand ("right", "left", "auto").
    var dominantHand: String = "right"
    /// Sensitivity preset: "calm", "balanced", "responsive".
    var gestureSensitivityPreset: String = "balanced"
    /// Coarse smoothing level 1–10 (maps to α range 0.06–0.20).
    var gestureSmoothing: Int = 5
    /// Show the gesture debug/diagnostics overlay by default.
    var showGestureDebugOverlay: Bool = false
    /// Reset the gesture calibration profile on next launch.
    var gestureCalibrationResetPending: Bool = false

    // ── Vision / Camera ──────────────────────────────────────────────────────
    /// When true, camera descriptions use `MiniMaxVisionProvider`; when false,
    /// only Apple on-device Vision is used.
    var useLLMForVision: Bool = true
    /// Separate vision-capable model (different from the chat text model).
    /// The standard text model (e.g. MiniMax-M2.7) does NOT support images.
    /// Set a vision-capable MiniMax model here, e.g. "abab7-preview".
    var miniMaxVisionModel: String = ""
    /// Maximum image width (pixels) when encoding camera frames for vision.
    /// Larger = richer detail but more tokens / latency. Default 1024.
    var visionImageMaxWidth: Int = 1024
    /// Automatically open the camera overlay when a vision command is processed.
    var visionAutoOpenOverlay: Bool = true
    /// Save visual descriptions to the memory / context store.
    var visionSaveToMemory: Bool = true
    /// Request verbose multi-sentence descriptions instead of concise summaries.
    var visionVerboseDescriptions: Bool = false

    // MARK: - Persisted daily-flag timestamps
    //
    // Each provider records the timestamp of its last "once-per-day" alert.
    // Gating logic compares `Calendar.isDate(_:inSameDayAs:)` so an app
    // restart during the morning window (or daylight savings) no longer
    // re-fires the alert.
    var lastMorningBriefingDate: Date? = nil
    var lastRainWarningDate:     Date? = nil
    var lastTodoistOverdueDate:  Date? = nil

    // MARK: - Android phone event settings
    /// Announce the caller's name when speaking incoming call alerts.
    var androidSpeakCallerNames: Bool = true
    /// Announce sender names when speaking SMS / WhatsApp alerts.
    var androidSpeakMessageSenders: Bool = true
    /// Include message body preview in spoken SMS / WhatsApp alerts.
    var androidShowMessagePreviews: Bool = true
    /// Suppress spoken alerts for WhatsApp messages (show in tray only).
    var androidMuteWhatsApp: Bool = false
    /// Suppress spoken alerts for SMS messages (show in tray only).
    var androidMuteSMS: Bool = false
    /// Speak generic app notification alerts (off by default — too noisy).
    var androidSpeakNotifications: Bool = false
    /// Auto-open the Android overlay when a call or message arrives.
    var androidAutoOpenOverlay: Bool = true

    var llmProviderModeRaw: String
    var miniMaxEnabled: Bool
    var miniMaxBaseURL: String
    var miniMaxModel: String
    var llamaCppEnabled: Bool
    var llamaCppBaseURL: String
    var llamaCppModel: String

    // ── Gemini (Google generative-language) ──────────────────────────────────
    /// Whether the Gemini text provider participates in `LLMRouter`.
    // ── xAI (Grok) ──────────────────────────────────────────────────────────
    var xaiEnabled: Bool = false
    /// Base URL for xAI API. Default: `https://api.x.ai/v1`.
    var xaiBaseURL: String = "https://api.x.ai/v1"
    /// Model name (e.g. `grok-3-mini`, `grok-3`, `grok-beta`).
    var xaiModel: String = "grok-3-mini"

    // ── Gemini ───────────────────────────────────────────────────────────────
    var geminiEnabled: Bool = false
    /// Base URL — defaults to the Google AI Studio v1beta REST endpoint.
    /// User-editable so an enterprise reverse-proxy can be substituted.
    var geminiBaseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    /// Text model name (e.g. `gemini-1.5-pro`, `gemini-2.5-flash`).  Free-form
    /// string — never hard-coded against a model enum so future models work
    /// without an app update.
    var geminiModel: String = "gemini-2.0-flash"
    /// Vision model name — same family, may be the same value as `geminiModel`.
    /// Most Gemini 1.5+ models are multimodal so the default mirrors the text
    /// model; users can override (e.g. `gemini-1.5-pro-vision`) if needed.
    var geminiVisionModel: String = "gemini-2.0-flash"

    // ── Vision provider routing ──────────────────────────────────────────────
    /// User's preferred vision provider.  Resolved at call time by
    /// `VisionProviderSelector`.  Stored as a raw string for forward
    /// compatibility (so a future "openai_vision" doesn't require a
    /// migration when added).  Values currently honoured: "minimax",
    /// "gemini", "apple".  Unknown values fall back to the auto-chain.
    var preferredVisionProviderRaw: String = "minimax"

    /// **Cloud-vision consent toggle.**  When false, NO camera frame leaves
    /// the machine — the selector always uses Apple on-device Vision
    /// regardless of `preferredVisionProviderRaw`.  Defaults to false on
    /// fresh installs so a new user must explicitly opt in to cloud vision.
    var cloudVisionConsent: Bool = false

    // ── GitHub issue logging (developer-facing) ──────────────────────────
    /// Master enable for the GitHub unknown-command issue logger.  Off
    /// by default — the local log still records every unknown command,
    /// but nothing leaves the machine until the developer opts in.
    var githubIssueLoggingEnabled: Bool = false
    /// GitHub username (informational — used in logs only, not the API).
    var githubIssueUsername: String = ""
    /// Owner of the repo issues are filed against — `chris` etc.
    var githubIssueRepoOwner: String = ""
    /// Repository name issues are filed against — `jarvis` etc.
    var githubIssueRepoName: String = ""
    /// Labels applied to every auto-created issue.  Comma-separated string
    /// for easy editing in Settings; split at submit time.
    var githubIssueLabelsCSV: String = "jarvis,unknown-command,needs-routing,auto-created"
    /// When true, an unknown command immediately tries to create a GitHub
    /// issue (subject to dedupe + cooldown).  When false the local log
    /// still records the event and the user can file an issue manually
    /// from the developer overlay later.
    var githubIssueAutoCreate: Bool = false
    /// Minimum seconds between two issue-creation attempts to the same
    /// repo, regardless of whether the second attempt is for a duplicate.
    /// Defends against issue-spam if the user holds down a button.
    var githubIssueCooldownSeconds: Int = 30
    /// Most recent GitHub API error string surfaced for the diagnostics
    /// row in Settings.  Reset whenever a creation succeeds.
    var githubIssueLastError: String? = nil
    /// URL of the most recently created issue — shown in Settings.
    var githubIssueLastCreatedURL: String? = nil

    // ── Settings UI ──────────────────────────────────────────────────────────
    /// When true, the Developer tab is visible in Settings.
    /// Defaults false so the tab stays hidden on first launch.
    var developerModeEnabled: Bool = false

    static let `default` = Preferences(
        userName: nil,
        preferredMicrophoneUID: nil,
        preferredCameraUID: nil,
        smartHomeBaseURL: nil,
        smartHomeToken: nil,
        androidTrustedDeviceIDs: [],
        webSocketPort: 17872,
        webSocketAuthToken: UUID().uuidString,  // auto-generated; shown in Settings QR
        requireWebSocketAuth: true,             // on by default — Tailscale is internet-routable
        wakeWord: .default,
        speechEngine: .apple,
        whisperModelPath: nil,
        sherpaModelDirectory: nil,
        sherpaKeywordsFilePath: nil,
        bargeInEnabled: false,
        bargeInSensitivity: 0.5,
        conversationalFollowUpEnabled: true,
        conversationalTimeoutSeconds: 8.0,
        screenWatchIntervalSeconds: 30.0,
        cameraWatchIntervalSeconds: 15.0,
        uiModeRaw: UIMode.orb.rawValue,
        statusStripVisible: false,
        operatingModeRaw: OperatingMode.normal.rawValue,
        ambientModeEnabled: false,
        safeMode: true,
        llmProviderModeRaw: LLMProviderMode.auto.rawValue,
        miniMaxEnabled: false,
        miniMaxBaseURL: "https://api.minimax.io/v1",
        miniMaxModel: "MiniMax-M2.7",
        llamaCppEnabled: false,
        llamaCppBaseURL: "http://localhost:8080/v1",
        llamaCppModel: ""
    )

    init(userName: String?,
         preferredMicrophoneUID: String?,
         preferredCameraUID: String?,
         smartHomeBaseURL: String?,
         smartHomeToken: String?,
         androidTrustedDeviceIDs: [String],
         webSocketPort: UInt16,
         webSocketAuthToken: String?,
         requireWebSocketAuth: Bool,
         wakeWord: WakeWordSettings,
         speechEngine: SpeechEngine,
         whisperModelPath: String?,
         sherpaModelDirectory: String?,
         sherpaKeywordsFilePath: String?,
         bargeInEnabled: Bool,
         bargeInSensitivity: Float,
         conversationalFollowUpEnabled: Bool,
         conversationalTimeoutSeconds: Double,
         screenWatchIntervalSeconds: Double,
         cameraWatchIntervalSeconds: Double,
         uiModeRaw: String,
         statusStripVisible: Bool,
         operatingModeRaw: String,
         ambientModeEnabled: Bool,
         safeMode: Bool,
         llmProviderModeRaw: String,
         miniMaxEnabled: Bool,
         miniMaxBaseURL: String,
         miniMaxModel: String,
         llamaCppEnabled: Bool,
         llamaCppBaseURL: String,
         llamaCppModel: String) {
        self.userName = userName
        self.preferredMicrophoneUID = preferredMicrophoneUID
        self.preferredCameraUID = preferredCameraUID
        self.smartHomeBaseURL = smartHomeBaseURL
        self.smartHomeToken = smartHomeToken
        self.androidTrustedDeviceIDs = androidTrustedDeviceIDs
        self.webSocketPort = webSocketPort
        self.webSocketAuthToken = webSocketAuthToken
        self.requireWebSocketAuth = requireWebSocketAuth
        self.wakeWord = wakeWord
        self.speechEngine = speechEngine
        self.whisperModelPath = whisperModelPath
        self.sherpaModelDirectory = sherpaModelDirectory
        self.sherpaKeywordsFilePath = sherpaKeywordsFilePath
        self.bargeInEnabled = bargeInEnabled
        self.bargeInSensitivity = bargeInSensitivity
        self.conversationalFollowUpEnabled = conversationalFollowUpEnabled
        self.conversationalTimeoutSeconds = conversationalTimeoutSeconds
        self.screenWatchIntervalSeconds = screenWatchIntervalSeconds
        self.cameraWatchIntervalSeconds = cameraWatchIntervalSeconds
        self.uiModeRaw = uiModeRaw
        self.statusStripVisible = statusStripVisible
        self.operatingModeRaw = operatingModeRaw
        self.ambientModeEnabled = ambientModeEnabled
        self.safeMode = safeMode
        self.llmProviderModeRaw = llmProviderModeRaw
        self.miniMaxEnabled = miniMaxEnabled
        self.miniMaxBaseURL = miniMaxBaseURL
        self.miniMaxModel = miniMaxModel
        self.llamaCppEnabled = llamaCppEnabled
        self.llamaCppBaseURL = llamaCppBaseURL
        self.llamaCppModel   = llamaCppModel
    }

    /// Tolerant decoder — anything missing from older preference files falls
    /// back to the Phase-1/2 defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName                  = try c.decodeIfPresent(String.self,           forKey: .userName)
        preferredMicrophoneUID    = try c.decodeIfPresent(String.self,           forKey: .preferredMicrophoneUID)
        preferredCameraUID        = try c.decodeIfPresent(String.self,           forKey: .preferredCameraUID)
        deskCameraUID             = try c.decodeIfPresent(String.self,           forKey: .deskCameraUID)
        smartHomeBaseURL          = try c.decodeIfPresent(String.self,           forKey: .smartHomeBaseURL)
        smartHomeToken            = try c.decodeIfPresent(String.self,           forKey: .smartHomeToken)
        todoistAPIToken               = try c.decodeIfPresent(String.self, forKey: .todoistAPIToken)
        githubPersonalAccessToken     = try c.decodeIfPresent(String.self, forKey: .githubPersonalAccessToken)
        googleCalendarEnabled         = try c.decodeIfPresent(Bool.self,   forKey: .googleCalendarEnabled) ?? true
        androidTrustedDeviceIDs   = try c.decodeIfPresent([String].self,         forKey: .androidTrustedDeviceIDs) ?? []
        webSocketPort             = try c.decodeIfPresent(UInt16.self,           forKey: .webSocketPort) ?? 17872
        // Existing installs: keep saved token; if none was ever set, generate one now.
        webSocketAuthToken        = try c.decodeIfPresent(String.self,           forKey: .webSocketAuthToken) ?? UUID().uuidString
        requireWebSocketAuth      = try c.decodeIfPresent(Bool.self,             forKey: .requireWebSocketAuth) ?? true
        var ww = try c.decodeIfPresent(WakeWordSettings.self, forKey: .wakeWord) ?? .default
        // Migrate pre-wake-word-default installs: if enabled was false and
        // there's no model (i.e. user never touched the setting), enable Apple wake word.
        if !ww.enabled, ww.modelIdentifier == nil { ww.enabled = true }
        wakeWord = ww
        speechEngine              = try c.decodeIfPresent(SpeechEngine.self,     forKey: .speechEngine) ?? .apple
        whisperModelPath          = try c.decodeIfPresent(String.self,           forKey: .whisperModelPath)
        sherpaModelDirectory      = try c.decodeIfPresent(String.self,           forKey: .sherpaModelDirectory)
        sherpaKeywordsFilePath    = try c.decodeIfPresent(String.self,           forKey: .sherpaKeywordsFilePath)
        bargeInEnabled                  = try c.decodeIfPresent(Bool.self,   forKey: .bargeInEnabled) ?? false
        bargeInSensitivity              = try c.decodeIfPresent(Float.self,  forKey: .bargeInSensitivity) ?? 0.5
        conversationalFollowUpEnabled   = try c.decodeIfPresent(Bool.self,   forKey: .conversationalFollowUpEnabled) ?? true
        conversationalTimeoutSeconds    = try c.decodeIfPresent(Double.self, forKey: .conversationalTimeoutSeconds) ?? 8.0
        persistentConversationEnabled   = try c.decodeIfPresent(Bool.self,   forKey: .persistentConversationEnabled) ?? true
        screenWatchIntervalSeconds      = try c.decodeIfPresent(Double.self, forKey: .screenWatchIntervalSeconds) ?? 30.0
        cameraWatchIntervalSeconds      = try c.decodeIfPresent(Double.self, forKey: .cameraWatchIntervalSeconds) ?? 15.0
        uiModeRaw                       = try c.decodeIfPresent(String.self, forKey: .uiModeRaw) ?? UIMode.orb.rawValue
        statusStripVisible              = try c.decodeIfPresent(Bool.self,   forKey: .statusStripVisible) ?? false
        operatingModeRaw                = try c.decodeIfPresent(String.self, forKey: .operatingModeRaw) ?? OperatingMode.normal.rawValue
        ambientModeEnabled              = try c.decodeIfPresent(Bool.self,   forKey: .ambientModeEnabled) ?? false
        safeMode                        = try c.decodeIfPresent(Bool.self,   forKey: .safeMode) ?? true

        // Emergency Safe Mode — defaults false (all subsystems enabled)
        emergencySafeMode = try c.decodeIfPresent(Bool.self, forKey: .emergencySafeMode) ?? false
        // Per-subsystem flags — default true so disabling emergency mode = old behaviour
        subsystemCameraEnabled                = try c.decodeIfPresent(Bool.self, forKey: .subsystemCameraEnabled)                ?? true
        subsystemWakeWordEnabled              = try c.decodeIfPresent(Bool.self, forKey: .subsystemWakeWordEnabled)              ?? true
        subsystemWebSocketEnabled             = try c.decodeIfPresent(Bool.self, forKey: .subsystemWebSocketEnabled)             ?? true
        subsystemTailscaleEnabled             = try c.decodeIfPresent(Bool.self, forKey: .subsystemTailscaleEnabled)             ?? true
        subsystemNewsEnabled                  = try c.decodeIfPresent(Bool.self, forKey: .subsystemNewsEnabled)                  ?? true
        subsystemWeatherProviderEnabled       = try c.decodeIfPresent(Bool.self, forKey: .subsystemWeatherProviderEnabled)       ?? true
        subsystemCalendarProviderEnabled      = try c.decodeIfPresent(Bool.self, forKey: .subsystemCalendarProviderEnabled)      ?? true
        subsystemTodoistProviderEnabled       = try c.decodeIfPresent(Bool.self, forKey: .subsystemTodoistProviderEnabled)       ?? true
        subsystemGitHubProviderEnabled        = try c.decodeIfPresent(Bool.self, forKey: .subsystemGitHubProviderEnabled)        ?? true
        subsystemHAProviderEnabled            = try c.decodeIfPresent(Bool.self, forKey: .subsystemHAProviderEnabled)            ?? true
        subsystemShopifyProviderEnabled       = try c.decodeIfPresent(Bool.self, forKey: .subsystemShopifyProviderEnabled)       ?? true
        subsystemObsidianEnabled              = try c.decodeIfPresent(Bool.self, forKey: .subsystemObsidianEnabled)              ?? true
        subsystemSemanticMemoryEnabled        = try c.decodeIfPresent(Bool.self, forKey: .subsystemSemanticMemoryEnabled)        ?? true
        subsystemConversationSummariserEnabled = try c.decodeIfPresent(Bool.self, forKey: .subsystemConversationSummariserEnabled) ?? true

        assistantName      = try c.decodeIfPresent(String.self,  forKey: .assistantName)   ?? "Jarvis"
        llmProviderModeRaw = try c.decodeIfPresent(String.self, forKey: .llmProviderModeRaw) ?? LLMProviderMode.auto.rawValue
        miniMaxEnabled     = try c.decodeIfPresent(Bool.self,   forKey: .miniMaxEnabled)  ?? false
        // Migrate saved base URLs forward.
        //  • Legacy path suffix:   old SDK used /v1/chatcompletion_v2 as the full URL;
        //                          reset to clean base.
        //  • minimaxi.io typo:     early Jarvis builds shipped with api.minimaxi.io
        //                          (extra "i"), which is not a real host. The correct
        //                          international base is api.minimax.io (no "i").
        //                          China users should set api.minimaxi.com manually.
        let rawMiniMaxURL  = try c.decodeIfPresent(String.self, forKey: .miniMaxBaseURL)
        if let rawMiniMaxURL {
            if rawMiniMaxURL.contains("chatcompletion_v2") {
                miniMaxBaseURL = "https://api.minimax.io/v1"   // legacy full-path → clean base
            } else if rawMiniMaxURL.contains("api.minimaxi.io") {
                miniMaxBaseURL = rawMiniMaxURL.replacingOccurrences(
                    of: "api.minimaxi.io", with: "api.minimax.io")  // typo fix
            } else {
                miniMaxBaseURL = rawMiniMaxURL
            }
        } else {
            miniMaxBaseURL = "https://api.minimax.io/v1"
        }
        miniMaxModel       = try c.decodeIfPresent(String.self, forKey: .miniMaxModel)    ?? "MiniMax-M2.7"
        // Migration: try new llamaCpp keys first; fall back to legacy lmStudio keys for
        // existing installs, resetting the base URL to the llama.cpp default (port 8080).
        let legacyC = try? decoder.container(keyedBy: LegacyLMStudioCodingKeys.self)
        llamaCppEnabled = try c.decodeIfPresent(Bool.self,   forKey: .llamaCppEnabled)
            ?? (try? legacyC?.decodeIfPresent(Bool.self, forKey: .lmStudioEnabled))
            ?? false
        if let saved = try c.decodeIfPresent(String.self, forKey: .llamaCppBaseURL) {
            llamaCppBaseURL = saved
        } else {
            // Old lmStudioBaseURL was localhost (LM Studio default). Reset to llama.cpp default.
            llamaCppBaseURL = "http://localhost:8080/v1"
        }
        llamaCppModel = try c.decodeIfPresent(String.self, forKey: .llamaCppModel)
            ?? (try? legacyC?.decodeIfPresent(String.self, forKey: .lmStudioModel))
            ?? ""

        // Gemini — defaults documented on the stored properties.
        xaiEnabled         = try c.decodeIfPresent(Bool.self,   forKey: .xaiEnabled)         ?? false
        xaiBaseURL         = try c.decodeIfPresent(String.self, forKey: .xaiBaseURL)         ?? "https://api.x.ai/v1"
        xaiModel           = try c.decodeIfPresent(String.self, forKey: .xaiModel)           ?? "grok-3-mini"
        geminiEnabled      = try c.decodeIfPresent(Bool.self,   forKey: .geminiEnabled)      ?? false
        geminiBaseURL      = try c.decodeIfPresent(String.self, forKey: .geminiBaseURL)      ?? "https://generativelanguage.googleapis.com/v1beta"
        geminiModel        = try c.decodeIfPresent(String.self, forKey: .geminiModel)        ?? "gemini-2.0-flash"
        geminiVisionModel  = try c.decodeIfPresent(String.self, forKey: .geminiVisionModel)  ?? "gemini-2.0-flash"

        // Vision routing — default to MiniMax for upgrade compat, cloud
        // consent defaults FALSE so an existing user with cloud-vision
        // disabled remains disabled until they explicitly opt in.
        preferredVisionProviderRaw = try c.decodeIfPresent(String.self, forKey: .preferredVisionProviderRaw) ?? "minimax"
        cloudVisionConsent         = try c.decodeIfPresent(Bool.self,   forKey: .cloudVisionConsent)         ?? false

        // GitHub issue logging — defaults match the struct definition.
        githubIssueLoggingEnabled  = try c.decodeIfPresent(Bool.self,   forKey: .githubIssueLoggingEnabled)  ?? false
        githubIssueUsername        = try c.decodeIfPresent(String.self, forKey: .githubIssueUsername)        ?? ""
        githubIssueRepoOwner       = try c.decodeIfPresent(String.self, forKey: .githubIssueRepoOwner)       ?? ""
        githubIssueRepoName        = try c.decodeIfPresent(String.self, forKey: .githubIssueRepoName)        ?? ""
        githubIssueLabelsCSV       = try c.decodeIfPresent(String.self, forKey: .githubIssueLabelsCSV)       ?? "jarvis,unknown-command,needs-routing,auto-created"
        githubIssueAutoCreate      = try c.decodeIfPresent(Bool.self,   forKey: .githubIssueAutoCreate)      ?? false
        githubIssueCooldownSeconds = try c.decodeIfPresent(Int.self,    forKey: .githubIssueCooldownSeconds) ?? 30
        githubIssueLastError       = try c.decodeIfPresent(String.self, forKey: .githubIssueLastError)
        githubIssueLastCreatedURL  = try c.decodeIfPresent(String.self, forKey: .githubIssueLastCreatedURL)

        // TTS
        ttsEngine          = try c.decodeIfPresent(TTSEngine.self, forKey: .ttsEngine)        ?? .appleSystem
        ttsVoiceIdentifier = try c.decodeIfPresent(String.self,    forKey: .ttsVoiceIdentifier)
        ttsRate            = try c.decodeIfPresent(Float.self,     forKey: .ttsRate)           ?? 0.5
        ttsPitch           = try c.decodeIfPresent(Float.self,     forKey: .ttsPitch)          ?? 1.0
        ttsVolume          = try c.decodeIfPresent(Float.self,     forKey: .ttsVolume)         ?? 1.0
        // Piper
        piperExecutablePath = try c.decodeIfPresent(String.self,   forKey: .piperExecutablePath)
        piperModelPath      = try c.decodeIfPresent(String.self,   forKey: .piperModelPath)
        piperConfigPath     = try c.decodeIfPresent(String.self,   forKey: .piperConfigPath)
        piperSpeakerId      = try c.decodeIfPresent(Int.self,      forKey: .piperSpeakerId)
        piperFallbackToApple = try c.decodeIfPresent(Bool.self,    forKey: .piperFallbackToApple) ?? true
        ttsBackendId         = try c.decodeIfPresent(String.self,  forKey: .ttsBackendId)         ?? "piper_onnx"
        // Web overlays
        webOverlaysEnabled        = try c.decodeIfPresent(Bool.self, forKey: .webOverlaysEnabled)        ?? false
        webOverlayAllowRemoteURLs = try c.decodeIfPresent(Bool.self, forKey: .webOverlayAllowRemoteURLs) ?? false
        webOverlayDebugEnabled    = try c.decodeIfPresent(Bool.self, forKey: .webOverlayDebugEnabled)    ?? false

        // Vision
        useLLMForVision          = try c.decodeIfPresent(Bool.self,   forKey: .useLLMForVision)          ?? true
        miniMaxVisionModel       = try c.decodeIfPresent(String.self, forKey: .miniMaxVisionModel)       ?? ""
        visionImageMaxWidth      = try c.decodeIfPresent(Int.self,    forKey: .visionImageMaxWidth)      ?? 1024
        visionAutoOpenOverlay    = try c.decodeIfPresent(Bool.self,   forKey: .visionAutoOpenOverlay)    ?? true
        visionSaveToMemory       = try c.decodeIfPresent(Bool.self,   forKey: .visionSaveToMemory)       ?? true
        visionVerboseDescriptions = try c.decodeIfPresent(Bool.self,  forKey: .visionVerboseDescriptions) ?? false

        // Shopify
        shopifyAccessToken        = try c.decodeIfPresent(String.self, forKey: .shopifyAccessToken)
        shopifyShopDomain         = try c.decodeIfPresent(String.self, forKey: .shopifyShopDomain)
        shopifyLowStockThreshold  = try c.decodeIfPresent(Int.self,    forKey: .shopifyLowStockThreshold) ?? 5

        // Spotify
        spotifyPersonalToken = try c.decodeIfPresent(String.self, forKey: .spotifyPersonalToken)

        // Obsidian
        obsidianVaultPath           = try c.decodeIfPresent(String.self,   forKey: .obsidianVaultPath)
        obsidianLLMContextEnabled   = try c.decodeIfPresent(Bool.self,     forKey: .obsidianLLMContextEnabled)   ?? true
        obsidianMaxContextNotes     = try c.decodeIfPresent(Int.self,      forKey: .obsidianMaxContextNotes)     ?? 3
        obsidianProactivityEnabled  = try c.decodeIfPresent(Bool.self,     forKey: .obsidianProactivityEnabled)  ?? true
        obsidianWatchTags           = try c.decodeIfPresent([String].self, forKey: .obsidianWatchTags)           ?? ["jarvis", "review", "urgent"]

        // HA Camera Alerts
        haCameraAlertsEnabled       = try c.decodeIfPresent(Bool.self,   forKey: .haCameraAlertsEnabled)         ?? true
        haDoorbellAlertsEnabled     = try c.decodeIfPresent(Bool.self,   forKey: .haDoorbellAlertsEnabled)       ?? true
        haMotionCooldownSeconds     = try c.decodeIfPresent(Double.self, forKey: .haMotionCooldownSeconds)       ?? 120
        haGlobalAlertCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .haGlobalAlertCooldownSeconds) ?? 20
        haMotionCameraMappings      = try c.decodeIfPresent([HAMotionCameraMapping].self, forKey: .haMotionCameraMappings) ?? []
        haDoorbellPhrase                = try c.decodeIfPresent(String.self, forKey: .haDoorbellPhrase)                ?? "Someone's at the door."
        handTrackingEnabled             = try c.decodeIfPresent(Bool.self,   forKey: .handTrackingEnabled)             ?? true
        dominantHand                    = try c.decodeIfPresent(String.self, forKey: .dominantHand)                    ?? "right"
        gestureSensitivityPreset        = try c.decodeIfPresent(String.self, forKey: .gestureSensitivityPreset)        ?? "balanced"
        gestureSmoothing                = try c.decodeIfPresent(Int.self,    forKey: .gestureSmoothing)                ?? 5
        showGestureDebugOverlay         = try c.decodeIfPresent(Bool.self,   forKey: .showGestureDebugOverlay)         ?? false
        gestureCalibrationResetPending  = try c.decodeIfPresent(Bool.self,   forKey: .gestureCalibrationResetPending)  ?? false

        // Persisted daily flag timestamps (defaults nil — first call after
        // restart will see "no previous fire" and is gated by the time-of-day
        // window logic in each provider).
        lastMorningBriefingDate = try c.decodeIfPresent(Date.self, forKey: .lastMorningBriefingDate)
        lastRainWarningDate     = try c.decodeIfPresent(Date.self, forKey: .lastRainWarningDate)
        lastTodoistOverdueDate  = try c.decodeIfPresent(Date.self, forKey: .lastTodoistOverdueDate)

        // Android phone events
        androidSpeakCallerNames     = try c.decodeIfPresent(Bool.self, forKey: .androidSpeakCallerNames)    ?? true
        androidSpeakMessageSenders  = try c.decodeIfPresent(Bool.self, forKey: .androidSpeakMessageSenders) ?? true
        androidShowMessagePreviews  = try c.decodeIfPresent(Bool.self, forKey: .androidShowMessagePreviews) ?? true
        androidMuteWhatsApp         = try c.decodeIfPresent(Bool.self, forKey: .androidMuteWhatsApp)        ?? false
        androidMuteSMS              = try c.decodeIfPresent(Bool.self, forKey: .androidMuteSMS)             ?? false
        androidSpeakNotifications   = try c.decodeIfPresent(Bool.self, forKey: .androidSpeakNotifications)  ?? false
        androidAutoOpenOverlay      = try c.decodeIfPresent(Bool.self, forKey: .androidAutoOpenOverlay)     ?? true

        // Distributed Brain / Windows Sidecar
        distributedBrainEnabled  = try c.decodeIfPresent(Bool.self,   forKey: .distributedBrainEnabled)  ?? false

        // Mac Brain Gateway unified port
        legacyAndroidPortEnabled = try c.decodeIfPresent(Bool.self,   forKey: .legacyAndroidPortEnabled) ?? false

        // JarvisBrainDaemon
        daemonEnabled                          = try c.decodeIfPresent(Bool.self, forKey: .daemonEnabled)                          ?? true
        legacyBrainServerEnabled               = try c.decodeIfPresent(Bool.self, forKey: .legacyBrainServerEnabled)               ?? false
        speakRemoteRepliesOnMac                = try c.decodeIfPresent(Bool.self, forKey: .speakRemoteRepliesOnMac)                ?? false
        showRemoteActivityInMacUI              = try c.decodeIfPresent(Bool.self, forKey: .showRemoteActivityInMacUI)              ?? true
        allowRemoteDevicesToTriggerTools       = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteDevicesToTriggerTools)       ?? true
        allowRemoteDevicesToTriggerHomeAssistant = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteDevicesToTriggerHomeAssistant) ?? false

        // Mac Brain HTTP server
        brainServerEnabled        = try c.decodeIfPresent(Bool.self,   forKey: .brainServerEnabled)        ?? false
        brainServerPort           = try c.decodeIfPresent(UInt16.self, forKey: .brainServerPort)           ?? 8765
        brainServerBindLocalOnly  = try c.decodeIfPresent(Bool.self,   forKey: .brainServerBindLocalOnly)  ?? false

        // Mac Camera HTTP server
        cameraServerEnabled      = try c.decodeIfPresent(Bool.self,   forKey: .cameraServerEnabled)      ?? false
        cameraServerRequireToken = try c.decodeIfPresent(Bool.self,   forKey: .cameraServerRequireToken) ?? true
        keepCameraWarm           = try c.decodeIfPresent(Bool.self,   forKey: .keepCameraWarm)           ?? false
        cameraFPS                = try c.decodeIfPresent(Int.self,    forKey: .cameraFPS)                ?? 5
        cameraJPEGQuality        = try c.decodeIfPresent(String.self, forKey: .cameraJPEGQuality)        ?? "medium"

        // Local LLM learning engine
        localLLMEnabled       = try c.decodeIfPresent(Bool.self,   forKey: .localLLMEnabled)       ?? false
        localLLMProvider      = try c.decodeIfPresent(String.self, forKey: .localLLMProvider)      ?? "openai_compatible"
        localLLMBaseURL       = try c.decodeIfPresent(String.self, forKey: .localLLMBaseURL)       ?? "http://localhost:1234"
        localLLMModelName     = try c.decodeIfPresent(String.self, forKey: .localLLMModelName)     ?? ""
        localLLMApiKey        = try c.decodeIfPresent(String.self, forKey: .localLLMApiKey)
        localLLMTimeoutSecs   = try c.decodeIfPresent(Int.self,    forKey: .localLLMTimeoutSecs)   ?? 30
        localLLMMaxTokens     = try c.decodeIfPresent(Int.self,    forKey: .localLLMMaxTokens)     ?? 256
        localLLMTemperature   = try c.decodeIfPresent(Double.self, forKey: .localLLMTemperature)   ?? 0.2

        // Conversational Jarvis
        conversationalModeEnabled          = try c.decodeIfPresent(Bool.self,   forKey: .conversationalModeEnabled)          ?? true
        conversationalSessionFlushDelay    = try c.decodeIfPresent(Double.self, forKey: .conversationalSessionFlushDelay)    ?? 5.0
        conversationalSaveRawTranscripts   = try c.decodeIfPresent(Bool.self,   forKey: .conversationalSaveRawTranscripts)   ?? false
        conversationalDailyNotesEnabled    = try c.decodeIfPresent(Bool.self,   forKey: .conversationalDailyNotesEnabled)    ?? true
        projectDocsPath                    = try c.decodeIfPresent(String.self, forKey: .projectDocsPath)
        projectKnowledgeEnabled            = try c.decodeIfPresent(Bool.self,   forKey: .projectKnowledgeEnabled)            ?? true
        conversationalMemoryAutoSave       = try c.decodeIfPresent(String.self, forKey: .conversationalMemoryAutoSave)       ?? "auto_project"
        conversationalDiagnosticsEnabled   = try c.decodeIfPresent(Bool.self,   forKey: .conversationalDiagnosticsEnabled)   ?? false
        codebaseIndexEnabled               = try c.decodeIfPresent(Bool.self,   forKey: .codebaseIndexEnabled)               ?? true
        codebaseIndexPath                  = try c.decodeIfPresent(String.self, forKey: .codebaseIndexPath)
        silentActionsEnabled               = try c.decodeIfPresent(Bool.self,   forKey: .silentActionsEnabled)               ?? true
        selfKnowledgeEnabled               = try c.decodeIfPresent(Bool.self,   forKey: .selfKnowledgeEnabled)               ?? true
        developerModeEnabled               = try c.decodeIfPresent(Bool.self,   forKey: .developerModeEnabled)               ?? false
    }
}

final class PreferencesStore {
    private let url: URL
    private let queue = DispatchQueue(label: "com.jarvis.mac.prefs", qos: .utility)
    private(set) var current: Preferences

    /// Called on the calling thread immediately after any `update(_:)` mutates `current`.
    var onDidUpdate: (() -> Void)?

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Restrict the directory to owner-only so other processes / users can't
        // enumerate our config files (API tokens, HA credentials, etc.)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        self.url = dir.appendingPathComponent("preferences.json")
        // Restrict existing file if it was previously created with world-readable perms
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        self.current = Self.load(from: url) ?? .default

        // Move any plaintext integration tokens out of preferences.json into the
        // macOS Keychain.  Runs once per install; no-op once tokens are nil.
        migratePlaintextTokensToKeychain()
    }

    private static func load(from url: URL) -> Preferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    func update(_ mutate: (inout Preferences) -> Void) {
        mutate(&current)
        onDidUpdate?()
        let snapshot = current
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: [.atomic])
                // Re-apply owner-only permissions after atomic write (which replaces the file)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
            }
        }
    }

    // MARK: - Keychain-backed token accessors
    //
    // These five tokens used to live in preferences.json plaintext.  They now
    // live in the macOS Keychain.  The accessors below are the canonical read
    // path for the rest of the app — they prefer the Keychain value but fall
    // back to the legacy plaintext field, which exists only during the
    // migration window (the field is nilled and persisted as soon as the
    // value is successfully copied into the Keychain).

    /// Home Assistant long-lived access token.
    var smartHomeToken: String? {
        Keychain.get(KeychainAccount.homeAssistantToken) ?? current.smartHomeToken
    }

    /// Todoist REST v2 API token.
    var todoistAPIToken: String? {
        Keychain.get(KeychainAccount.todoistAPIToken) ?? current.todoistAPIToken
    }

    /// GitHub Personal Access Token.
    var githubPersonalAccessToken: String? {
        Keychain.get(KeychainAccount.githubPersonalAccessToken) ?? current.githubPersonalAccessToken
    }

    /// Shopify Admin REST access token.
    var shopifyAccessToken: String? {
        Keychain.get(KeychainAccount.shopifyAccessToken) ?? current.shopifyAccessToken
    }

    /// Spotify personal access token (OAuth Playground).
    var spotifyPersonalToken: String? {
        Keychain.get(KeychainAccount.spotifyPersonalToken) ?? current.spotifyPersonalToken
    }

    /// Home Assistant WebSocket authentication token (shown as QR code in Settings).
    var webSocketAuthToken: String? {
        Keychain.get(KeychainAccount.webSocketAuthToken) ?? current.webSocketAuthToken
    }

    /// True iff a token is set (anywhere — Keychain or legacy prefs).  Use
    /// this in Settings UI for the green-dot "configured" indicator.
    func hasSecureToken(account: String) -> Bool {
        if let v = Keychain.get(account), !v.isEmpty { return true }
        return false
    }

    /// Update a token in the Keychain.  Pass empty string to clear.  Also
    /// triggers `update { _ in }` so any `@Observable` UI listening to prefs
    /// re-renders to reflect the configured/cleared state.
    func setSecureToken(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.remove(account)
        } else {
            Keychain.set(trimmed, for: account)
        }
        // Force an empty mutation so observers (Settings UI green-dot,
        // diagnostics) recompute.  No prefs field changes.
        update { _ in }
    }

    // MARK: - Plaintext → Keychain migration

    /// One-shot migration that moves any plaintext integration tokens out of
    /// `preferences.json` and into the macOS Keychain.  Idempotent: if the
    /// fields are already nil (i.e. previously migrated) it does nothing.
    ///
    /// **Safety:** each token is migrated only if the Keychain write *and*
    /// readback both succeed.  If either step fails the plaintext value is
    /// left untouched and a warning is logged, so the user never loses a
    /// configured token to a failed Keychain operation.
    func migratePlaintextTokensToKeychain() {
        // Local helper closure — moves one stored field into the Keychain.
        // Returns true if anything was actually changed (caller persists).
        func migrate(field plaintext: String?,
                     to account: String,
                     clear: (inout Preferences) -> Void) -> Bool {
            guard let plaintext, !plaintext.isEmpty else { return false }
            // If the Keychain already has this token, just clear the plaintext
            // copy — that's already the post-migration state.
            if let existing = Keychain.get(account), !existing.isEmpty {
                Log.app.info("token_migration: \(account, privacy: .public) already in Keychain; clearing plaintext copy")
                current = applyMutation(current, clear)
                return true
            }
            // Try the write.
            Keychain.set(plaintext, for: account)
            // Verify by read-back — if the Keychain is locked or restricted
            // and the write silently failed, this will return nil/different.
            guard let readBack = Keychain.get(account), readBack == plaintext else {
                Log.app.warning("token_migration: Keychain write+readback FAILED for \(account, privacy: .public); leaving plaintext token in place")
                return false
            }
            Log.app.info("token_migration: \(account, privacy: .public) successfully moved to Keychain; clearing plaintext field")
            current = applyMutation(current, clear)
            return true
        }

        var anyMigrated = false
        anyMigrated = migrate(field: current.smartHomeToken,
                              to: KeychainAccount.homeAssistantToken,
                              clear: { $0.smartHomeToken = nil }) || anyMigrated
        anyMigrated = migrate(field: current.todoistAPIToken,
                              to: KeychainAccount.todoistAPIToken,
                              clear: { $0.todoistAPIToken = nil }) || anyMigrated
        anyMigrated = migrate(field: current.githubPersonalAccessToken,
                              to: KeychainAccount.githubPersonalAccessToken,
                              clear: { $0.githubPersonalAccessToken = nil }) || anyMigrated
        anyMigrated = migrate(field: current.shopifyAccessToken,
                              to: KeychainAccount.shopifyAccessToken,
                              clear: { $0.shopifyAccessToken = nil }) || anyMigrated
        anyMigrated = migrate(field: current.spotifyPersonalToken,
                              to: KeychainAccount.spotifyPersonalToken,
                              clear: { $0.spotifyPersonalToken = nil }) || anyMigrated
        anyMigrated = migrate(field: current.webSocketAuthToken,
                              to: KeychainAccount.webSocketAuthToken,
                              clear: { $0.webSocketAuthToken = nil }) || anyMigrated

        if anyMigrated {
            // Persist cleaned preferences synchronously so a crash mid-launch
            // doesn't leave the plaintext token in the file.
            persistSync()
        }
    }

    /// Apply an inout mutation to a Preferences value and return the result.
    private func applyMutation(_ value: Preferences,
                                _ mutate: (inout Preferences) -> Void) -> Preferences {
        var copy = value
        mutate(&copy)
        return copy
    }

    /// Synchronous persist — used by the launch-time migrator before the rest
    /// of the app starts reading prefs.  Async `update()` is the normal path.
    private func persistSync() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}

// MARK: - Migration keys for lmStudio → llamaCpp rename

/// Used only in Preferences.init(from:) to read old JSON keys written by
/// pre-llama.cpp Jarvis builds. Never written back to disk.
private enum LegacyLMStudioCodingKeys: String, CodingKey {
    case lmStudioEnabled
    case lmStudioBaseURL
    case lmStudioModel
}
