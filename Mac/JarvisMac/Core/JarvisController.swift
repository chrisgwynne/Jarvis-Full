import Foundation
import AppKit
import AVFoundation
import Speech
import SwiftUI

/// The single orchestrator. Owns every long-lived service, wires
/// wake-word → STT → intent → action/TTS, and pipes status into `AppState`
/// for the UI. Barge-in, latency tracking, vision analysis, context, and
/// Home Assistant routing are all driven from here.
@MainActor
final class JarvisController {

    // Stores
    let state: AppState
    let prefs: PreferencesStore
    let history: CommandHistoryStore
    let context: ContextEngine
    let contextStore: ContextStore
    let latency = LatencyTracker()
    let wakeFeedback = WakeWordFeedbackLog()

    // Memory
    private let database: JarvisDatabase?
    let conversations: ConversationStore?
    let memories: MemoryStore?
    let snapshots: ContextSnapshotStore?
    let search: SearchService?
    let sessionId = UUID().uuidString
    private var lastSearchQuery: String = ""

    // Audio
    let audioDevices: AudioDeviceManager
    private(set) var recognizer: SpeechRecognizing
    private let appleRecognizer: AppleSpeechRecognizer
    private let whisperRecognizer: WhisperSpeechRecognizer?
    var tts: TextToSpeaking
    private let appleTTS: AVSpeechTTS     // always alive as Apple fallback
    let piperTTS: PiperTTS       // always alive; active only when selected
    let pronunciationDictionary: PronunciationDictionary
    let speechPreprocessor: SpeechPreprocessor
    private(set) var wakeWord: WakeWordDetecting

    // Vision
    let camera: CameraManager
    private(set) var vision: VisionAnalyzing
    private let motion = MotionDetector()
    private var motionLastSummary: Date = .distantPast
    let cameraAwareness: CameraAwarenessService

    // Screen awareness
    let screenCapture: ScreenCaptureService
    let screenAwareness: ScreenAwarenessService

    // Ambient context engine
    let ambientContext = AmbientContextEngine()
    let taskThreadEngine = TaskThreadEngine()

    // Context graph — unified relationship index over all context sources
    let contextGraph = ProjectRelationshipIndex.shared

    // Conversation runtime — owns conversation state machine + timers + event publishing
    let conversation = ConversationRuntime()

    // Networking / integrations
    private let server: WebSocketServer
    /// Exposed so AndroidBridgeManager can call broadcast() on it.
    var wsServer: WebSocketServer { server }
    private(set) var androidBridge: AndroidBridgeManager?
    private(set) var androidEventReceiver: AndroidEventReceiver?
    /// Mac→Android capability execution orchestrator (Phase 8).
    let androidToolOrchestrator = AndroidToolOrchestrator.shared
    let tailscale = TailscaleService()
    private(set) var smartHome: SmartHomeClient
    /// User-defined friendly name → HA entity ID alias map.
    let homeAliases = HomeEntityAliasStore()
    private var lastKnownEntities: [HomeEntity] = []

    // Calendar + Todoist
    let calendarService = EventKitCalendarService()
    private(set) var todoistClient: TodoistAPIClient?

    // GitHub
    private(set) var githubClient: GitHubAPIClient?
    private(set) var githubModule: GitHubModule?

    // Spotify client moved to SpotifyIntentHandler (Sprint P)

    // Home Assistant entity registry + motion-camera mapper
    let haEntityRegistry = HAEntityRegistry()
    let haMotionMapper   = HAMotionCameraMapper()

    // Proactivity providers
    private var calendarProactivityProvider: CalendarProactivityProvider?
    private var todoistProactivityProvider:  TodoistProactivityProvider?
    private var githubProactivityProvider:   GitHubProactivityProvider?
    private var weatherProactivityProvider:  WeatherProactivityProvider?
    private var haProactivityProvider:       HomeAssistantProactivityProvider?
    private var shopifyProactivityProvider:  ShopifyProactivityProvider?
    private var obsidianProactivityProvider: ObsidianProactivityProvider?
    private var emailProactivityProvider:    EmailProactivityProvider?

    // Obsidian vault
    private(set) lazy var obsidianVault: ObsidianVaultService = ObsidianVaultService(prefs: prefs)

    // Weather
    let weatherService = WeatherService()

    // Actions
    let actions: MacActionExecutor

    // Overlays
    let overlayManager = OverlayManager()
    let webOverlayManager = WebOverlayManager()
    let spatialOverlay = OverlaySceneManager()       // legacy bridge (no-op, spatial is ambient)
    let spatialCoordinator = SpatialAmbientCoordinator() // ambient spatial layer

    // Widget lifecycle management
    let widgetManager = WidgetManager()

    // Tasks
    private var router: IntentRouter
    private var listeningTask: Task<Void, Never>?
    private var speakingObserverTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?
    private var latencyPublishTask: Task<Void, Never>?
    private var conversationalTimeoutTask: Task<Void, Never>?
    /// B6: Watchdog task that detects and recovers a stalled wake-word service.
    private var wakeWordWatchdogTask: Task<Void, Never>?

    // Stability / emergency containment
    /// Resource watchdog — monitors resident memory and fires emergency stop.
    /// Exposed so SettingsView can display current memory reading.
    private(set) var healthMonitor: JarvisHealthMonitor?
    /// Immediate-flush crash breadcrumb log. Writes on every subsystem start/stop.
    private let breadcrumb = CrashBreadcrumbLog.shared

    // Conversational session
    private var conversationalSessionActive = false
    /// True for 10 minutes after the last wake event or speech — allows
    /// follow-up commands without re-saying "Jarvis".
    private var conversationalArmed = false
    private var conversationalArmTask: Task<Void, Never>?
    /// Set synchronously in speak() so that the post-loop can detect a pending
    /// TTS utterance without racing against the async isSpeakingStream observer.
    /// Checked with a 500ms window: if speak() was called <0.5s ago, TTS is
    /// likely pending even if state.isSpeaking hasn't flipped to true yet.
    private var lastSpeakCalledAt: Date = .distantPast

    // Permanent speech failure guard (Dictation disabled, auth error, etc.)
    // Prevents rapid wake→STT→fail→restart loops. Cleared automatically on
    // successful speech or when the user explicitly re-enables listening.
    private var permanentSpeechFailureActive = false

    // Conversational pending-question state.
    // Set when Jarvis asks the user something and needs a follow-up reply.
    // Consumed and cleared by FollowUpResolver on the next transcript.
    private(set) var activePendingContext: PendingConversationContext?
    private var awaitingResponseTimeoutTask: Task<Void, Never>?

    // Active listening session — nil when not listening
    private var activeSession: ListeningSession?

    // SystemBus subscription — pauses STT when an audio-bearing overlay opens
    private var audioOverlayToken: SystemBus.SubscriptionToken?

    // Screen watch
    private var screenWatchTask: Task<Void, Never>?

    // Toast
    private var toastClearTask: Task<Void, Never>?

    // Response playbook
    let playbook: ResponseTemplateStore
    private(set) var renderer: ResponseRenderer

    // Personality
    let personality: PersonalityFileStore
    let contextBuilder: PersonalityContextBuilder

    // Sprint 8.5 foundational systems
    let attention: AttentionEngine
    let activityTimeline: ActivityTimelineStore
    let notificationQueue: NotificationQueue
    let entityGraph: EntityGraph
    let reasoning: ReasoningStore

    // Sprint 9 news
    let newsStore: NewsStore
    let newsScheduler: NewsRefreshScheduler
    let newsChannelStore: NewsChannelStore

    // Reddit integration — model/client/store all live under News-adjacent
    // module.  Scheduler-less for now; refresh on overlay open + voice command.
    let redditStore: RedditStore = RedditStore()

    // Phrase-store matching
    let phraseStore: CommandPhraseStore
    private let phraseMatcher = CommandPhraseMatcher()

    // Natural-language layer
    let unmatched = UnmatchedCommandStore()
    /// GitHub-issue logger for unknown commands.  Driven by Settings —
    /// noop when `githubIssueLoggingEnabled = false`.
    lazy var githubIssueService: GitHubIssueService = GitHubIssueService(prefs: prefs)

    // LLM reasoning layer
    let llmRouter: LLMRouter

    // A14: Conversation summariser — compresses recent turns into long-term memories
    private(set) lazy var conversationSummariser: ConversationSummariser? = {
        guard let conv = conversations, let mem = memories else { return nil }
        return ConversationSummariser(convStore: conv, memStore: mem, llmRouter: llmRouter)
    }()

    // A15: Semantic memory index — NLEmbedding-based vector search
    private(set) lazy var semanticIndex: SemanticMemoryIndex = SemanticMemoryIndex()

    // Latency — fast path + circuit protection
    private let fastRouter    = FastResponseRouter()
    let circuitBreaker = LLMProviderCircuitBreaker()
    /// Handles LLM fallback routing. Created during bootstrap, callbacks wired then.
    private(set) var llmFallbackHandler: LLMFallbackHandler?
    /// Handles all Shopify-domain intents. Created during bootstrap.
    private(set) var shopifyIntentHandler: ShopifyIntentHandler!
    /// Handles all Spotify-domain intents. Created during bootstrap.
    private(set) var spotifyIntentHandler: SpotifyIntentHandler!
    /// Handles Weather intents. Created during bootstrap.
    private(set) var weatherIntentHandler: WeatherIntentHandler!
    /// Handles Todoist intents. Created during bootstrap.
    private(set) var todoistIntentHandler: TodoistIntentHandler!
    /// Handles Calendar intents. Created during bootstrap.
    private(set) var calendarIntentHandler: CalendarIntentHandler!
    /// Handles Home Assistant intents. Created during bootstrap.
    private(set) var haIntentHandler: HomeAssistantIntentHandler!
    /// Handles GitHub intents. Created during bootstrap.
    private(set) var gitHubIntentHandler: GitHubIntentHandler!
    /// Handles Reddit intents. Created during bootstrap.
    private(set) var redditIntentHandler: RedditIntentHandler!
    private(set) var notesIntentHandler: NotesIntentHandler!
    private(set) var emailIntentHandler: EmailIntentHandler!

    // Mac Brain HTTP server + Camera streaming
    private var brainServer: MacBrainServer?
    let gatewayDiagnostics = GatewayDiagnostics()
    /// Backward-compat alias — Settings views that reference `brainDiagnostics` continue to work.
    var brainDiagnostics: GatewayDiagnostics { gatewayDiagnostics }

    // Sprint P7: Distributed Brain
    let distributedDiagnostics = DistributedBrainDiagnostics.shared

    // Camera service components — created once, lifetime = app lifetime.
    let cameraService    = MacCameraService()
    let cameraFrameStore = MacCameraFrameStore()
    let cameraDiagnostics = MacCameraDiagnostics()
    /// Wires VisionModule callbacks into ProactivityEngine. Held so weak-self captures stay live.
    private var visionEventBridge: VisionEventBridge?

    // Sprint AD: Local Learning Engine
    let learningEngine = LocalLearningEngine()

    // Sprint L: Visual Intelligence — POI surveillance system
    let visionModule = VisionModule.shared

    // Sprint K: Conversational Jarvis — dual-lane routing + project knowledge
    let conversationRouter   = ConversationRouter()
    private(set) lazy var projectKnowledge: ProjectKnowledgeService = {
        let svc = ProjectKnowledgeService(
            memories:  memories,
            search:    search,
            obsidian:  obsidianVault,
            convMemory: ConversationMemoryStore.shared
        )
        svc.projectDocsPath = prefs.current.projectDocsPath
        return svc
    }()
    private(set) lazy var answerComposer: JarvisAnswerComposer = {
        JarvisAnswerComposer(
            llmRouter:      llmRouter,
            contextBuilder: contextBuilder,
            activeContext:  ActiveContextRegistry.shared,
            graphIndex:     ProjectRelationshipIndex.shared
        )
    }()
    private(set) lazy var memoryExtractor: MemoryExtractor = {
        MemoryExtractor(llmRouter: llmRouter)
    }()
    private(set) lazy var obsidianExporter: ObsidianExporter = ObsidianExporter()
    /// When true, the current session's automatic memory saves are suppressed.
    private var memoryLoggingPaused: Bool = false
    /// Last conversation route result for diagnostics.
    private var lastConvRouteResult: ConversationRouteResult? = nil
    let capabilities           = CapabilityRegistry()
    let identityService        = AssistantIdentityService()

    // macOS system control
    let systemController = MacSystemController()

    // Timer & stopwatch service
    let timerService = TimerService()

    // Proactivity engine — receives signals from news, system, etc.
    let proactivity = ProactivityEngine()

    // Persistent proactive orchestrator — attention-gated delivery on top of ProactivityEngine.
    let orchestrator = ProactivityOrchestrator.shared

    // Timing engine — tracks silence gaps for well-timed proactive delivery.
    let timingEngine = ConversationalTimingEngine.shared

    // Central world state — aggregated snapshot of app, media, calendar, conversation context.
    let worldState = AmbientWorldState.shared
    private var worldStateAggregator: WorldStateAggregator?

    // Runtime health monitor — surfaces repeated STT/TTS/LLM failures to the user.
    let runtimeHealthMonitor = RuntimeHealthMonitor.shared

    // Rolling dialogue memory — short-term contextual turns for pronoun resolution + LLM injection.
    let rollingMemory = RollingDialogueMemory.shared

    /// When true, the next call to speak() will skip TTS output. Used for
    /// dual-track silent action execution: the command leg of CHAT_PLUS_TOOL
    /// sets this so its confirmation ("Turning on…") is suppressed.
    var suppressNextSpeak = false

    // MARK: - Remote brain routing (Phase 4 daemon bridge)
    /// Closure installed during handleRemoteTranscript to capture the first spoken text.
    /// Cleared immediately after the routing pipeline returns.
    private var remoteResponseCapture: ((String) -> Void)? = nil
    /// Ordered dedup set for remote routeIds. Capped at 200 entries (FIFO eviction).
    private var handledRemoteRouteIds: [String] = []

    // Persistent notification store — cross-session deduplication.
    let proactiveNotificationStore = ProactiveNotificationStore()

    // Startup readiness gate — gates proactivity until system is stable.
    let startupCoordinator = StartupCoordinator()

    // Response cache — stores deterministic answers for a TTL
    private let responseCache = ResponseCache()

    // Acknowledgement phrases for LLM-bound queries (cycled to avoid repetition)
    private let llmAcknowledgements = ["Let me check.", "One moment.", "On it.", "Looking into that.", "Working on it."]

    /// Process-global registry of recent context items from every subsystem.
    /// Reads + writes via `ActiveContextRegistry.shared` so subsystems and
    /// the conversational layer share one source of truth without threading
    /// a reference through every constructor.
    var activeContext: ActiveContextRegistry { ActiveContextRegistry.shared }

    /// Pluggable web-search backend.  Defaults to the noop (no provider) —
    /// real Brave/DDG/etc. implementations replace it via Settings later.
    let webSearch: WebSearchProvider = NoopWebSearchProvider()
    private var llmAckIndex = -1

    // Camera frameTap throttle — accessed from the capture queue, so it
    // must be nonisolated. Target ≤ 4 fps to the MainActor Task queue;
    // the full 30fps feed still reaches the CameraAwarenessService which
    // does its own interval management.
    nonisolated(unsafe) private var lastFrameTapTime: TimeInterval = 0

    init(state: AppState,
         prefs: PreferencesStore = PreferencesStore(),
         history: CommandHistoryStore = CommandHistoryStore()) {
        self.state = state
        self.prefs = prefs
        // Gate proactivity immediately — before any signal can arrive.
        // The gate is lifted by startupCoordinator.markReady() at the end
        // of bootstrap() after the grace period expires.
        proactivity.startupCoordinator  = startupCoordinator
        proactivity.notificationStore   = proactiveNotificationStore
        self.history = history
        self.contextStore = ContextStore()
        self.context = ContextEngine(store: contextStore)
        self.audioDevices = AudioDeviceManager(prefs: prefs)
        self.camera = CameraManager(prefs: prefs)
        let apple = AppleSpeechRecognizer()
        let whisper: WhisperSpeechRecognizer? = prefs.current.whisperModelPath
            .map { WhisperSpeechRecognizer(modelPath: $0) }
        self.appleRecognizer = apple
        self.whisperRecognizer = whisper
        if prefs.current.speechEngine == .whisper, let whisper {
            self.recognizer = whisper
        } else {
            self.recognizer = apple
        }
        let aTTS = AVSpeechTTS()
        let pTTS = PiperTTS()
        aTTS.configure(prefs: prefs.current)
        pTTS.configure(prefs: prefs.current)
        pTTS.fallbackTTS = aTTS
        self.appleTTS = aTTS
        self.piperTTS  = pTTS
        // Active engine depends on saved pref
        self.tts = prefs.current.ttsEngine == .piper ? pTTS : aTTS
        // Speech preprocessing (pronunciation + markdown stripping)
        let pronDict = PronunciationDictionary()
        self.pronunciationDictionary = pronDict
        self.speechPreprocessor = SpeechPreprocessor(dictionary: pronDict)
        self.actions = MacActionExecutor()
        self.server = WebSocketServer(port: prefs.current.webSocketPort)

        // LLM router — created early so LLMVisionAnalyzer can reference it.
        let xaiProv = XAIProvider(
            baseURL:   { prefs.current.xaiBaseURL },
            modelName: { prefs.current.xaiModel },
            enabled:   { prefs.current.xaiEnabled },
            apiKey:    { Keychain.get(KeychainAccount.xaiAPIKey) }
        )
        let miniMaxProv = MiniMaxProvider(
            baseURL:   { prefs.current.miniMaxBaseURL },
            modelName: { prefs.current.miniMaxModel },
            enabled:   { prefs.current.miniMaxEnabled },
            apiKey:    { Keychain.get(KeychainAccount.miniMaxAPIKey) }
        )
        let geminiProv = GeminiProvider(
            baseURL:     { prefs.current.geminiBaseURL },
            modelName:   { prefs.current.geminiModel },
            visionModel: { prefs.current.geminiVisionModel },
            enabled:     { prefs.current.geminiEnabled },
            apiKey:      { Keychain.get(KeychainAccount.geminiAPIKey) }
        )
        let localProv = LlamaCppProvider(
            baseURL:   { prefs.current.llamaCppBaseURL },
            modelName: { prefs.current.llamaCppModel },
            enabled:   { prefs.current.llamaCppEnabled }
        )
        let localRouter = LLMRouter(xai:     xaiProv,
                                    miniMax: miniMaxProv,
                                    gemini:  geminiProv,
                                    local:   localProv)
        self.llmRouter = localRouter

        // ── Vision pipeline: two separate paths for different use-cases ──────────
        //
        // PATH 1 — Background watch (LLMVisionAnalyzer → LLMRouter)
        //   Used by: captureScene(), CameraOCRService, PresenceDetectionService.
        //   Routes through the shared LLMRouter so background tasks share
        //   provider selection and the circuit-breaker with the chat pipeline.
        //   Checks `useLLMForVision` at call time — toggle in Settings is instant.
        let appleVision  = AppleVisionAnalyzer()
        let visionAnalyzer = LLMVisionAnalyzer(
            llm:       localRouter,
            fallback:  appleVision,
            state:     state,
            maxWidth:  { prefs.current.visionImageMaxWidth },
            isEnabled: { prefs.current.useLLMForVision }
        )
        self.vision = visionAnalyzer

        // PATH 2 — User-facing description (MiniMaxVisionProvider → OpenAIChatClient direct)
        //   Used by: captureDescription() — "what can you see", person/desk/OCR commands.
        //   Bypasses LLMRouter intentionally: has its own OpenAIChatClient + timeout so a
        //   slow vision response never trips the text-chat circuit-breaker.
        //   modelName falls back to the text model — MiniMax M2+ is multimodal and accepts
        //   image inputs on the same endpoint; a dedicated vision model is only needed to
        //   route to a different model tier (e.g. abab7-preview).
        let miniMaxVisionProv = MiniMaxVisionProvider(
            baseURL:   { prefs.current.miniMaxBaseURL },
            modelName: {
                // Use a dedicated vision model if configured.
                // Otherwise fall back to the text model — MiniMax M2+ is
                // multimodal and accepts image inputs on the same endpoint,
                // so a separate vision model is only needed for routing to a
                // different model tier (e.g. abab7-preview).
                let vm = prefs.current.miniMaxVisionModel.trimmingCharacters(in: .whitespaces)
                return vm.isEmpty ? prefs.current.miniMaxModel : vm
            },
            apiKey:    { Keychain.get(KeychainAccount.miniMaxAPIKey) },
            isEnabled: { prefs.current.useLLMForVision && prefs.current.miniMaxEnabled },
            maxWidth:  { prefs.current.visionImageMaxWidth },
            appState:  state
        )
        self.smartHome = Self.buildSmartHomeClient(from: prefs)
        // Wire alias store into the REST client so entity resolution checks
        // user-defined aliases before falling back to fuzzy matching.
        if let haClient = self.smartHome as? HomeAssistantRESTClient {
            haClient.aliasStore = homeAliases
        }
        self.wakeWord = NoopWakeWord()
        self.router = IntentRouter()
        let pb = ResponseTemplateStore()
        self.playbook = pb
        self.renderer = ResponseRenderer(store: pb)
        self.phraseStore = CommandPhraseStore()

        let pers = PersonalityFileStore()
        self.personality = pers
        self.contextBuilder = PersonalityContextBuilder(store: pers)

        // Sprint 8.5 systems (lightweight, no async init needed)
        self.attention = AttentionEngine()
        self.activityTimeline = ActivityTimelineStore()
        self.notificationQueue = NotificationQueue()
        self.entityGraph = EntityGraph()
        self.reasoning = ReasoningStore()

        // Memory — open SQLite; if it fails we run without persistence.
        let db = Self.openDatabase()
        self.database = db
        if let db {
            let conv = ConversationStore(db: db)
            let mem  = MemoryStore(db: db)
            let snap = ContextSnapshotStore(db: db)
            self.conversations = conv
            self.memories = mem
            self.snapshots = snap
            self.search = SearchService(convStore: conv, memStore: mem, snapshotStore: snap)
            // Sprint 9 news — backed by same database
            let ns = NewsStore(db: db)
            self.newsStore = ns
            self.newsScheduler = NewsRefreshScheduler(store: ns)
        } else {
            self.conversations = nil
            self.memories = nil
            self.snapshots = nil
            self.search = nil
            // Fallback: news without persistence (won't happen in practice)
            let tmpPath = NSTemporaryDirectory() + "jarvis_news_\(Int(Date().timeIntervalSinceReferenceDate)).sqlite3"
            let fallbackDB: JarvisDatabase
            do {
                fallbackDB = try JarvisDatabase(url: URL(fileURLWithPath: tmpPath))
            } catch {
                Log.app.error("[init] Fallback news DB failed: \(error.localizedDescription, privacy: .public)")
                preconditionFailure("Cannot open temporary news database at \(tmpPath): \(error.localizedDescription)")
            }
            let ns = NewsStore(db: fallbackDB)
            self.newsStore = ns
            self.newsScheduler = NewsRefreshScheduler(store: ns)
        }
        // News channels (live video) — separate from RSS feeds.
        self.newsChannelStore = NewsChannelStore()

        // Screen awareness
        let capture = ScreenCaptureService()
        self.screenCapture = capture
        self.screenAwareness = ScreenAwarenessService(capture: capture, vision: visionAnalyzer)

        // Camera awareness — primary description calls use MiniMaxVisionProvider.
        let awareness = CameraAwarenessService(
            camera: self.camera,
            vision: visionAnalyzer,
            motion: self.motion
        )
        // Vision selector — the user's preferred cloud provider OR Apple,
        // resolved at call time.  Replaces the hard-wired MiniMax-only
        // assignment so Settings → Vision can pick Gemini at any moment
        // without a restart.  See VisionProviderSelector for the chain
        // and the cloud-consent gate.
        let geminiVisionProv = GeminiVisionProvider(
            provider:  geminiProv,
            isEnabled: { prefs.current.useLLMForVision && prefs.current.geminiEnabled },
            maxWidth:  { prefs.current.visionImageMaxWidth },
            appState:  state
        )
        let appleVisionProv = AppleVisionFallbackProvider()
        let selector = VisionProviderSelector(
            prefs:    prefs,
            minimax:  miniMaxVisionProv,
            gemini:   geminiVisionProv,
            apple:    appleVisionProv,
            appState: state
        )
        awareness.visionProvider = selector
        self.cameraAwareness = awareness

    }

    private static func openDatabase() -> JarvisDatabase? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("jarvis.sqlite3")
        do {
            let db = try JarvisDatabase(url: url)
            Log.memory.info("database opened at \(url.path)")
            return db
        } catch {
            Log.memory.error("database open failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        // ── Always-on: health monitor + crash breadcrumb log ─────────────────
        // Start these BEFORE any other subsystem so we have a log trail even if
        // the very first subsystem causes a crash.
        let hm = JarvisHealthMonitor()
        hm.memoryThresholdMB = 800
        hm.onEmergencyStop = { [weak self] reason in
            self?.forceEmergencyStop(reason: reason)
        }
        healthMonitor = hm
        hm.start()

        breadcrumb.write(subsystem: "app", action: "bootstrap_start",
                         detail: "emergencySafeMode=\(prefs.current.emergencySafeMode)")

        // ── Emergency Safe Mode gate ──────────────────────────────────────────
        // When emergencySafeMode is true (default), skip ALL subsystems.
        // The UI window and Settings are fully functional. Re-enable subsystems
        // one at a time in Settings > General, then restart Jarvis.
        if prefs.current.emergencySafeMode {
            breadcrumb.write(subsystem: "app", action: "emergency_mode_active",
                             detail: "all subsystems disabled — use Settings > General to re-enable")
            state.log("app", .warn,
                      "⚠️ EMERGENCY SAFE MODE — all subsystems disabled. " +
                      "Open Settings > General to re-enable them one at a time.")

            // Minimal UI restore (no async work, no network, no audio)
            if let savedMode = UIMode(rawValue: prefs.current.uiModeRaw) {
                state.uiMode = savedMode
            }
            state.statusStripVisible = prefs.current.statusStripVisible
            state.safeMode = true   // force visual safeMode indicator in emergency
            syncPersonality()
            syncLLMMode()
            syncOperatingMode()

            notificationQueue.onDeliver = { [weak self] event in
                guard let self else { return }
                self.showToast(event.title, icon: event.symbol)
            }

            startupCoordinator.advance(to: .loadingSettings)
            startupCoordinator.markReady()
            syncStartupDiagnostics()
            state.log("app", .info, "Jarvis bootstrap complete (emergency safe mode)")
            context.setPhase(state.phase)
            return
        }

        // ── Startup phase: settings ──────────────────────────────────────────
        startupCoordinator.advance(to: .loadingSettings)
        syncStartupDiagnostics()

        // 1. Permissions
        let micGranted = await requestMicAccess()
        state.microphoneStatus = micGranted ? .ready : .denied

        let speechGranted = await appleRecognizer.requestAuthorization()
        state.speechStatus = speechGranted ? .ready : .denied

        let camGranted = await camera.requestAuthorization()
        state.cameraStatus = camGranted ? .ready : .denied

        // 2. Devices
        state.availableMicrophones = audioDevices.enumerate()
        state.availableCameras = camera.enumerate()
        state.preferredMicrophoneUID = audioDevices.preferredUID
        state.preferredCameraUID = camera.preferredUID
        state.activeMicrophoneName = audioDevices.resolvePreferred()?.localizedName
        if state.availableMicrophones.isEmpty {
            state.microphoneStatus = .unavailable("No input devices")
        }
        if state.availableCameras.isEmpty {
            state.cameraStatus = .unavailable("No camera connected")
        }
        state.speechEngine = recognizer.engine
        state.isOffline = recognizer.isOffline
        state.whisperStatus = (whisperRecognizer != nil) ? .ready : .unavailable("Model not configured")
        refreshTTSState()

        // ── Startup phase: audio ─────────────────────────────────────────────
        startupCoordinator.advance(to: .loadingAudio)
        syncStartupDiagnostics()

        // Wire web overlay bridge → AppState diagnostics + command handler
        webOverlayManager.onBridgeMessage = { [weak self] type, payload in
            self?.handleWebBridgeMessage(type, payload: payload)
        }
        refreshWebOverlayState()
        WebOverlayLoader.ensureDirectoryExists()

        // ── Startup phase: camera ────────────────────────────────────────────
        startupCoordinator.advance(to: .loadingCamera)
        syncStartupDiagnostics()

        // 3. Camera + frame tap — gated by subsystemCameraEnabled
        if prefs.current.subsystemCameraEnabled {
            breadcrumb.subsystemStart("camera")
            if camGranted, !state.availableCameras.isEmpty {
                do { try camera.startPreview() }
                catch { state.cameraStatus = .failed(error.localizedDescription) }
                // Start desk (secondary) camera if configured
                if let deskUID = prefs.current.deskCameraUID {
                    camera.startSession(role: .secondary, deviceUID: deskUID)
                }
            }
            camera.frameTap = { [weak self] frame in
                // Throttle to ≤ 4 fps delivered to the MainActor.
                // The capture pipeline fires at ~30 fps; dispatching a
                // MainActor Task every frame creates ~30 context switches/sec
                // and constant SwiftUI state churn. Most Jarvis state
                // (motion, face count) doesn't need sub-250ms precision.
                let now = CACurrentMediaTime()
                guard let self, now - self.lastFrameTapTime >= 0.25 else { return }
                self.lastFrameTapTime = now
                Task { @MainActor [weak self] in self?.handleFrame(frame) }
            }
        } else {
            breadcrumb.subsystemSkipped("camera")
        }

        // Wire CameraAwarenessService callbacks
        cameraAwareness.onSceneChange = { [weak self] event in
            guard let self else { return }
            self.state.lastSceneSummary = event.scene.summary
            self.state.lastSceneOCR = event.scene.ocrLines
            self.state.lastSceneTimestamp = event.scene.timestamp
            self.state.lastCameraSummary = event.scene.summary
            self.state.faceCount = event.scene.peopleCount
            SceneChangeDetector.shared.reportPresence(
                isPresent: event.scene.peopleCount > 0,
                confidence: event.scene.peopleCount > 0 ? 0.85 : 0.90
            )
            if event.sceneChanged || event.scene.peopleCount > 0 {
                self.context.recordCameraScene(event.scene)
                self.context.recordCameraWatch("watch tick: \(event.scene.summary.prefix(60))")
                self.snapshots?.save(
                    phase: self.state.phase.rawValue,
                    lastIntent: "cameraWatch",
                    lastResponse: event.scene.summary,
                    sessionId: self.sessionId
                )
            }
        }
        cameraAwareness.onMotionEvent = { [weak self] event in
            guard let self else { return }
            self.state.motionDetected = event.delta > 0.04
            self.context.recordCameraMotion(event)
        }

        // 4. WebSocket server + bridge + Tailscale — see AndroidBridgeBootstrapper.swift
        let androidResult = AndroidBridgeBootstrapper.bootstrap(
            controller: self, server: server, state: state, prefs: prefs,
            proactivity: proactivity, context: context,
            syncPrefs: syncAndroidEventReceiverPrefs)
        androidBridge = androidResult.bridge
        androidEventReceiver = androidResult.receiver
        AndroidBridgeBootstrapper.wireTailscale(tailscale, state: state, prefs: prefs)

        // ── Startup phase: speech ────────────────────────────────────────────
        startupCoordinator.advance(to: .loadingSpeech)
        syncStartupDiagnostics()

        // 5. TTS speaking signal → AppState lifecycle.
        // Extracted to `rewireSpeakingObserver()` so it can be called again
        // when the TTS engine is switched at runtime.
        rewireSpeakingObserver()

        // 7. Wake word — gated by subsystemWakeWordEnabled
        if prefs.current.subsystemWakeWordEnabled {
            breadcrumb.subsystemStart("wake_word")
            // rebuildWakeWord builds and starts the right implementation
            // (sherpa if configured, else NoopWakeWord). Do not call start()
            // again here: the protocol method is `throws` and SherpaWakeWordService
            // isn't idempotent — a second start would leak the previous spotter
            // and double-install the tap. wireTriggers() inside rebuildWakeWord()
            // updates isWakeArmed + phase. The watchdog is started automatically.
            await rebuildWakeWord()
        } else {
            breadcrumb.subsystemSkipped("wake_word")
        }

        // 7a. Always-on listening lifecycle: claim a power-activity
        // assertion so macOS doesn't App-Nap throttle the audio
        // pipeline, and observe sleep/wake to restore passive wake
        // listening after the Mac wakes back up.
        syncDesiredListeningMode()   // set initial desired mode from prefs
        prefs.onDidUpdate = { [weak self] in
            self?.syncDesiredListeningMode()
        }
        acquireListeningActivityIfWanted()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.log("system", .info,
                    "system_will_sleep — pausing wake/STT")
                if self.wakeWord.isRunning {
                    self.wakeWord.stop()
                    self.state.isWakeArmed = false
                }
                if self.state.isListening {
                    self.stopListening(reason: .stateTransition)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strong = self else { return }
                strong.state.log("system", .info,
                    "system_did_wake — restoring passive wake")
                // Give CoreAudio a beat to settle its HAL after wake.
                try? await Task.sleep(nanoseconds: 800_000_000)
                // Refresh available devices in case the preferred mic
                // came back on a different port.
                strong.state.availableMicrophones = strong.audioDevices.enumerate()
                strong.returnToPassiveWake(reason: .stateTransition)
            }
        }

        // ── Startup phase: overlays ──────────────────────────────────────────
        startupCoordinator.advance(to: .loadingOverlays)
        syncStartupDiagnostics()

        // 8. Screen recording permission (best-effort; no alert shown here)
        await screenAwareness.checkPermission()
        state.screenPermissionGranted = screenAwareness.permissionGranted

        // Seed active app and keep state.activeApp in sync with NSWorkspace
        state.activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, let name = app?.localizedName else { return }
                self.state.activeApp = name
                self.entityGraph.recordAppOpen(name)
                self.activityTimeline.record(kind: .appSwitch, title: name)
            }
        }

        // 9. Home Assistant initial fetch — fire-and-forget so configure() never
        // blocks waiting for a network response. If HA is unreachable (wrong
        // network, VPN required, etc.) the sync await was stalling the entire
        // startup sequence for the full HTTP timeout (10-60s).
        state.homeAssistantStatus = smartHome.isConfigured ? .ready : .unavailable("Not configured")
        if smartHome.isConfigured {
            Task { [weak self] in await self?.refreshHomeAssistant() }
        }

        // 10. Intent router resolves HA entities from the cached snapshot.
        router.homeEntityResolver = { [weak self] phrase in
            self?.lastKnownEntities.first(where: { entity in
                let h = (entity.friendlyName ?? entity.entityID).lowercased()
                return h.contains(phrase)
            })?.entityID
        }
        router.lockEntityResolver = { [weak self] phrase in
            // Prefer lock.* entities; fall back to any entity containing the phrase.
            guard let entities = self?.lastKnownEntities else { return nil }
            let locks = entities.filter { $0.entityID.hasPrefix("lock.") }
            return (locks.first(where: { ($0.friendlyName ?? $0.entityID).lowercased().contains(phrase) })
                ?? entities.first(where: { ($0.friendlyName ?? $0.entityID).lowercased().contains(phrase) }))?.entityID
        }

        // 11. Latency snapshot + attention evaluation + context sync every ~1s
        //     Also mirrors startup grace-period countdown into AppState so the
        //     Debug HUD shows a live timer without the coordinator needing a
        //     direct reference to AppState.
        latencyPublishTask = Task { @MainActor [weak self] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.state.latencyMillis = self.latency.snapshot()
                self.tickAttentionAndContext()
                // Propagate grace period countdown
                if self.startupCoordinator.gracePeriodRemaining > 0 {
                    self.syncStartupDiagnostics()
                }
            }
        }

        // 12. Restore persisted UI preferences
        if let savedMode = UIMode(rawValue: prefs.current.uiModeRaw) {
            state.uiMode = savedMode
        }
        state.statusStripVisible = prefs.current.statusStripVisible

        // 13. Sync personality → response style + address
        syncPersonality()

        // 14. Start attention engine
        attention.start()

        // 15. Restore operating mode
        if let mode = OperatingMode(rawValue: prefs.current.operatingModeRaw) {
            state.operatingMode = mode
        }
        state.ambientModeEnabled = prefs.current.ambientModeEnabled
        syncOperatingMode()

        // 16. Restore LLM router mode
        syncLLMMode()

        // 17. Propagate performance mode
        state.safeMode = prefs.current.safeMode

        // 16. Wire notification queue delivery
        notificationQueue.onDeliver = { [weak self] event in
            guard let self else { return }
            self.showToast(event.title, icon: event.symbol)
            if event.priority >= .important {
                self.speak(event.title, critical: event.priority == .critical)
            }
            self.state.pendingNotificationCount = self.notificationQueue.pending.count
        }

        // ── Startup phase: memory ────────────────────────────────────────────
        startupCoordinator.advance(to: .loadingMemory)
        syncStartupDiagnostics()

        // Wire proactivity drain callback BEFORE starting news scheduler so any
        // signals produced during startup are re-evaluated correctly after the
        // grace period rather than being silently lost.
        startupCoordinator.onDrainQueue = { [weak self] signals in
            guard let self else { return }
            Log.app.info("[startup] draining \(signals.count, privacy: .public) queued signals")
            for signal in signals {
                self.proactivity.ingest(signal, appState: self.state)
            }
        }
        startupCoordinator.onPhaseChange = { [weak self] phase in
            self?.syncStartupDiagnostics()
        }

        // 17–19. ProactivityEngine callbacks + news + all proactivity providers
        // See ProactivityProviderRegistry.swift for full implementation.
        let provResult = ProactivityProviderRegistry.setup(
            engine: proactivity, state: state, prefs: prefs,
            overlayManager: overlayManager, weatherService: weatherService,
            calendarService: calendarService, smartHome: smartHome,
            haEntityRegistry: haEntityRegistry, haMotionMapper: haMotionMapper,
            obsidianVault: obsidianVault, newsStore: newsStore,
            newsScheduler: newsScheduler, notificationQueue: notificationQueue,
            llmRouter: llmRouter,
            speak: { [weak self] t in self?.speak(t) },
            showToast: { [weak self] m, i in self?.showToast(m, icon: i) },
            openArticle: { [weak self] a in self?.openArticle(a) })
        todoistClient               = provResult.todoistClient
        weatherProactivityProvider  = provResult.weatherProvider
        calendarProactivityProvider = provResult.calendarProvider
        todoistProactivityProvider  = provResult.todoistProvider
        githubClient                = provResult.githubClient
        githubModule                = provResult.githubModule
        githubProactivityProvider   = provResult.githubProvider
        haProactivityProvider       = provResult.haProvider
        shopifyProactivityProvider  = provResult.shopifyProvider
        obsidianProactivityProvider = provResult.obsidianProvider

        // Wire EmailProactivityProvider
        let emailProvider = EmailProactivityProvider(engine: proactivity, appState: state)
        emailProvider.start()
        emailProactivityProvider = emailProvider

        // 20. Seed identity into ContextEngine so LLM fallback always has it
        syncIdentity()

        // 19. Ensure soul directory exists + seed example files on first launch
        identityService.ensureDirectoryExists()

        // 21. Start timer service and wire expiry notifications
        timerService.onTimerExpired = { [weak self] timer in
            guard let self else { return }
            let spoken = self.renderer.render(ResponseKey.timerExpired, ["name": timer.name])
            self.speak(spoken)
            let signal = ProactivitySignal(
                source: .system,
                title: "Timer finished: \(timer.name)",
                body: "Your \(timer.name) timer has expired.",
                category: "timer",
                priority: .urgent,
                dedupeKey: "timer.expired.\(timer.id.uuidString)",
                spokenText: spoken,
                requiresAttention: true)
            self.proactivity.ingest(signal, appState: self.state)
        }
        timerService.start()

        // ── A15: Semantic memory index — gated by subsystemSemanticMemoryEnabled
        if prefs.current.subsystemSemanticMemoryEnabled {
            breadcrumb.subsystemStart("semantic_memory")
            // Force the lazy property so the index loads its persisted embeddings
            // before the first query, then attach it to SearchService so
            // hybridSearch() can use it.
            let semIdx = semanticIndex
            search?.semanticIndex = semIdx

            // Index any existing memories in the background so first queries
            // benefit from semantic matching immediately.
            if let mem = memories {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let allMems = await mem.all(limit: 500)
                    self.semanticIndex.indexBatch(
                        allMems.map { (id: "mem-\($0.id)", text: $0.text) }
                    )
                    self.state.log("memory", .info,
                        "semantic_index seeded entries=\(self.semanticIndex.entryCount)")
                }
            }
        } else {
            breadcrumb.subsystemSkipped("semantic_memory")
        }

        // ── A14: Conversation summariser — gated by subsystemConversationSummariserEnabled
        if prefs.current.subsystemConversationSummariserEnabled,
           let summariser = conversationSummariser {
            breadcrumb.subsystemStart("conversation_summariser")
            Task { await summariser.dailySummarise() }
        } else {
            breadcrumb.subsystemSkipped("conversation_summariser")
        }

        // ── AmbientContextEngine — passive app/screen awareness
        // P0: JARVIS_SAFE_MODE env var disables ALL screen sampling at startup.
        // Also respected by Settings → Safe Mode toggle (safeMode pref).
        // Launch with: JARVIS_SAFE_MODE=1 open JarvisMac.app
        let envSafeMode = ProcessInfo.processInfo.environment["JARVIS_SAFE_MODE"] != nil
        if envSafeMode {
            Log.app.warning("[JarvisController] JARVIS_SAFE_MODE active — ambient screen sampling disabled")
            prefs.update { $0.safeMode = true }
            state.safeMode = true
        }
        ambientContext.screenAwareness = screenAwareness
        ambientContext.contextEngine = context
        ambientContext.samplingIntervalSeconds = max(15, prefs.current.screenWatchIntervalSeconds)
        // In safe mode, also disable ambient screen sampling (keeps app tracking but skips OCR/capture).
        let ambientAllowed = prefs.current.ambientModeEnabled && !prefs.current.safeMode
        ambientContext.samplingEnabled = ambientAllowed
        ambientContext.setEnabled(prefs.current.ambientModeEnabled)  // app tracking still runs

        // ── Startup complete ─────────────────────────────────────────────────
        // Determine degraded vs fully ready.
        let systemsDegraded = (state.microphoneStatus == .denied)
            || (state.speechStatus == .denied)
        if systemsDegraded {
            startupCoordinator.markDegradedReady()
        } else {
            startupCoordinator.markReady()
        }

        // Wire ConversationRuntime callbacks so it can drive audio without a direct reference.
        conversation.onStartListening = { [weak self] in self?.startConversationalListening() }
        conversation.onStopListening = { [weak self] reason in self?.stopListening(reason: reason) }
        conversation.onReturnToPassiveWake = { [weak self] reason in self?.returnToPassiveWake(reason: reason) }
        conversation.isListening = { [weak self] in self?.state.isListening ?? false }
        conversation.isSpeaking = { [weak self] in self?.state.isSpeaking ?? false }
        conversation.listeningEnabled = { [weak self] in self?.state.listeningEnabled ?? true }
        conversation.mediaIsPlaying = { [weak self] in self?.state.mediaPlaybackState.isPlaying ?? false }
        conversation.conversationalTimeoutSeconds = { [weak self] in self?.prefs.current.conversationalTimeoutSeconds ?? 8 }
        conversation.followUpEnabled = { [weak self] in self?.prefs.current.conversationalFollowUpEnabled ?? true }
        conversation.persistentConversationEnabled = { [weak self] in self?.prefs.current.persistentConversationEnabled ?? true }
        Task { try? await conversation.start() }

        // Register subsystems + mark RuntimeCoordinator ready — see RuntimeBootstrapper.swift
        RuntimeBootstrapper.registerAndMarkReady(
            appState: state,
            conversation: conversation,
            systemsDegraded: systemsDegraded)

        // Legacy bridge — no longer opens a card, just a no-op shell kept for
        // the ⌘⇧S shortcut compatibility.
        spatialOverlay.overlayManager = overlayManager

        // Start ambient spatial coordinator — passive hand tracking across the
        // entire Jarvis stage. No voice command needed to activate it.
        await spatialCoordinator.start(cameraManager: camera)
        spatialCoordinator.onHUDAction = { [weak self] action in
            guard let self else { return }
            Task { @MainActor in
                switch action {
                case .openNews:        self.openOverlay(.news)
                case .openCamera:      self.openOverlay(.camera)
                case .openMemory:      self.openOverlay(.memory)
                case .openDiagnostics: self.openOverlay(.runtimeDiagnostics)
                case .closeOverlay:    _ = self.overlayManager.closeTop()
                case .resetView:       self.spatialCoordinator.resetView()
                case .pinOverlay:      self.overlayManager.pinTopOverlay()
                case .maximizeOverlay:
                    if let top = self.overlayManager.topOverlay {
                        self.overlayManager.toggleMaximize(id: top.id)
                    }
                }
            }
        }

        // Spatial overlay drag — the coordinator calls back whenever the user
        // pinch-drags an overlay panel. Commit as a manual frame immediately
        // so SwiftUI re-renders the panel at the new position on every frame.
        spatialCoordinator.onOverlayMove = { [weak self] id, frame in
            guard let self else { return }
            Task { @MainActor in
                self.overlayManager.setManualFrame(id: id, frame: frame)
            }
        }

        // Two-hand spread resize — coordinator provides the desired new size.
        // Centre the resized frame on the panel's current centre.
        spatialCoordinator.onOverlayResize = { [weak self] id, newSize in
            guard let self else { return }
            Task { @MainActor in
                guard let currentFrame = self.spatialCoordinator.currentOverlayFrame(for: id) else { return }
                let newFrame = CGRect(
                    x:      currentFrame.midX - newSize.width  / 2,
                    y:      currentFrame.midY - newSize.height / 2,
                    width:  newSize.width,
                    height: newSize.height
                )
                self.overlayManager.setManualFrame(id: id, frame: newFrame)
            }
        }

        // Start TaskThreadEngine passive activity tracking.
        taskThreadEngine.start()

        // Wire VisionModule motion/threat callbacks — see VisionEventBridge.swift
        let visionBridge = VisionEventBridge(proactivity: proactivity, appState: state)
        visionBridge.wire(to: visionModule)
        visionEventBridge = visionBridge

        syncStartupDiagnostics()

        // Living documentation — register built-in contributors so the
        // help overlay and conversational lookup see the actual feature
        // set the moment they're queried.  Contributors read live state
        // at section() time so toggling Settings updates docs instantly.
        registerBuiltInDocumentationContributors()

        // Wire ShopifyIntentHandler — see ShopifyIntentHandler.swift
        let shopifyHandler = ShopifyIntentHandler(prefs: prefs, renderer: renderer)
        shopifyHandler.speak      = { [weak self] t in self?.speak(t) }
        shopifyHandler.openOverlay = { [weak self] k in self?.openOverlay(k) }
        shopifyIntentHandler = shopifyHandler

        // Wire SpotifyIntentHandler — see SpotifyIntentHandler.swift
        let spotifyHandler = SpotifyIntentHandler(prefs: prefs, renderer: renderer)
        spotifyHandler.speak = { [weak self] t in self?.speak(t) }
        spotifyIntentHandler = spotifyHandler

        // Wire WeatherIntentHandler — see WeatherIntentHandler.swift
        let weatherHandler = WeatherIntentHandler(weatherService: weatherService, renderer: renderer)
        weatherHandler.speak = { [weak self] t in self?.speak(t) }
        weatherIntentHandler = weatherHandler

        // Wire TodoistIntentHandler — see TodoistIntentHandler.swift
        let todoistHandler = TodoistIntentHandler(
            prefs: prefs, renderer: renderer,
            storedClient: { [weak self] in self?.todoistClient })
        todoistHandler.speak             = { [weak self] t   in self?.speak(t) }
        todoistHandler.setPendingContext  = { [weak self] ctx in self?.setPendingContext(ctx) }
        todoistHandler.currentTranscript  = { [weak self] in self?.context.snapshot.lastCommand ?? "" }
        todoistIntentHandler = todoistHandler

        // Wire CalendarIntentHandler — see CalendarIntentHandler.swift
        let calendarHandler = CalendarIntentHandler(calendarService: calendarService, renderer: renderer)
        calendarHandler.speak             = { [weak self] t   in self?.speak(t) }
        calendarHandler.setPendingContext  = { [weak self] ctx in self?.setPendingContext(ctx) }
        calendarHandler.currentTranscript  = { [weak self] in self?.context.snapshot.lastCommand ?? "" }
        calendarIntentHandler = calendarHandler

        // Wire HomeAssistantIntentHandler — see HomeAssistantIntentHandler.swift
        let haHandler = HomeAssistantIntentHandler(
            haEntityRegistry: haEntityRegistry, haMotionMapper: haMotionMapper,
            proactivity: proactivity, renderer: renderer, state: state)
        haHandler.speak             = { [weak self] t   in self?.speak(t) }
        haHandler.openOverlay       = { [weak self] k   in self?.openOverlay(k) }
        haHandler.closeOverlay      = { [weak self] k   in self?.overlayManager.close(k) }
        haHandler.setPendingContext  = { [weak self] ctx in self?.setPendingContext(ctx) }
        haHandler.currentTranscript  = { [weak self] in self?.context.snapshot.lastCommand ?? "" }
        haHandler.getSmartHome      = { [weak self] in self?.smartHome ?? DisabledSmartHomeClient() }
        haHandler.statusSummary     = { [weak self] in await self?.homeStatusSummary() ?? "" }
        haHandler.entityLookup      = { [weak self] in self?.lastKnownEntities ?? [] }
        haIntentHandler = haHandler

        // Wire GitHubIntentHandler — see GitHubIntentHandler.swift
        let ghHandler = GitHubIntentHandler(renderer: renderer, prefs: prefs)
        ghHandler.speak       = { [weak self] t in self?.speak(t) }
        ghHandler.openOverlay = { [weak self] k in self?.openOverlay(k) }
        ghHandler.getModule   = { [weak self] in self?.githubModule }
        gitHubIntentHandler = ghHandler

        // Wire RedditIntentHandler — see RedditIntentHandler.swift
        let redditHandler = RedditIntentHandler(redditStore: redditStore, state: state, llmRouter: llmRouter)
        redditHandler.speak       = { [weak self] t in self?.speak(t) }
        redditHandler.openOverlay = { [weak self] k in self?.openOverlay(k) }
        redditIntentHandler = redditHandler

        // Wire NotesIntentHandler — see NotesIntentHandler.swift
        let notesHandler = NotesIntentHandler(renderer: renderer)
        notesHandler.speak             = { [weak self] t in self?.speak(t) }
        notesHandler.setPendingContext = { [weak self] ctx in self?.activePendingContext = ctx }
        notesHandler.currentTranscript = { [weak self] in self?.context.snapshot.lastCommand ?? "" }
        notesHandler.ingestNode = { node in
            Task { @MainActor in
                _ = ContextGraph.shared.upsertNode(node)
            }
        }
        notesIntentHandler = notesHandler

        // Wire EmailIntentHandler — see EmailIntentHandler.swift
        let emailHandler = EmailIntentHandler(renderer: renderer)
        emailHandler.speak             = { [weak self] t in self?.speak(t) }
        emailHandler.setPendingContext = { [weak self] ctx in self?.activePendingContext = ctx }
        emailHandler.currentTranscript = { [weak self] in self?.context.snapshot.lastCommand ?? "" }
        emailHandler.ingestNode = { node in
            Task { @MainActor in
                _ = ContextGraph.shared.upsertNode(node)
            }
        }
        emailIntentHandler = emailHandler

        // Wire LLMFallbackHandler — see LLMFallbackHandler.swift
        let fallbackHandler = LLMFallbackHandler(
            llmRouter: llmRouter,
            circuitBreaker: circuitBreaker,
            state: state,
            renderer: renderer,
            context: context,
            contextBuilder: contextBuilder,
            prefs: prefs,
            search: search,
            memories: memories,
            obsidianVault: obsidianVault,
            latency: latency,
            unmatched: unmatched)
        fallbackHandler.getPendingContext  = { [weak self] in self?.activePendingContext }
        fallbackHandler.speak              = { [weak self] text in self?.speak(text) }
        fallbackHandler.executeIntent      = { [weak self] intent in await self?.execute(intent) }
        fallbackHandler.setPendingContext  = { [weak self] ctx in self?.setPendingContext(ctx) }
        fallbackHandler.shouldAcknowledgeQuery = { [weak self] text in
            self?.shouldAcknowledgeLLMQuery(text) ?? false
        }
        llmFallbackHandler = fallbackHandler

        // Wire LocalLearningEngine into fallback handler + configure from prefs
        let llmConfig = buildLocalLLMConfig()
        learningEngine.configure(config: llmConfig)
        learningEngine.routeFromString = { [weak self] intentString -> (intent: String, target: String?)? in
            guard let self else { return nil }
            let resolved = self.router.route(intentString)
            if case .unknown = resolved { return nil }
            return (intent: intentString, target: nil)
        }
        fallbackHandler.learningEngine  = learningEngine
        fallbackHandler.routeFromString = { [weak self] intentString -> Intent? in
            guard let self else { return nil }
            let resolved = self.router.route(intentString)
            if case .unknown = resolved { return nil }
            return resolved
        }

        // Wire VisionActionPipeline for CHAT_PLUS_TOOL_PLUS_REASONING route
        VisionActionPipeline.shared.onOpenCamera = { [weak self] in
            self?.openOverlay(.camera)
        }
        VisionActionPipeline.shared.captureVisionSummary = { [weak self] () async -> String? in
            guard let self else { return nil }
            let (desc, _) = await self.cameraAwareness.captureDescription(mode: .describe)
            return desc.isEmpty ? nil : desc
        }
        VisionActionPipeline.shared.onFallback = { [weak self] message in
            self?.speak(message)
        }
        VisionActionPipeline.shared.onLLMReason = { [weak self] contextBlock, query in
            guard let self else { return }
            await self.speakWithToolContext(query: query, context: contextBlock)
        }

        ScreenshotActionPipeline.shared.captureScreenshot = { [weak self] () async -> String? in
            guard let self else { return nil }
            let scene = await self.cameraAwareness.captureScene()
            return scene.summary.isEmpty ? nil : scene.summary
        }
        ScreenshotActionPipeline.shared.onLLMReason = { [weak self] contextBlock, query in
            guard let self else { return }
            await self.speakWithToolContext(query: query, context: contextBlock)
        }
        ScreenshotActionPipeline.shared.onFallback = { [weak self] message in
            self?.speak(message)
        }

        PostToolContextInjection.shared.onInjectAndReason = { [weak self] contextBlock, query in
            guard let self else { return }
            await self.speakWithToolContext(query: query, context: contextBlock)
        }
        PostToolContextInjection.shared.onFallback = { [weak self] message in
            self?.speak(message)
        }

        // Wire context graph source closures
        contextGraph.getTaskThreads   = { [weak self] in self?.taskThreadEngine.threads ?? [] }
        contextGraph.getMemories      = { ConversationMemoryStore.shared.memoryItems }
        contextGraph.getObsidianNotes = { [weak self] in
            guard let self, prefs.current.obsidianVaultPath != nil else { return [] }
            return Array(obsidianVault.notes.values)
        }
        contextGraph.getTraces              = { ExecutionTracer.shared.recentTraces(limit: 20) }
        contextGraph.getGitHubNotifications = { [] }   // no sync cache; wire when caching is added
        contextGraph.getTodoistTasks        = { [] }   // no sync cache; wire when caching is added
        // Load persisted graph before first ingestion so history survives restarts
        contextGraph.loadFromDisk()
        // Initial background ingestion — does not block bootstrap
        Task.detached(priority: .utility) { await MainActor.run { [weak self] in
            self?.contextGraph.refresh()
        }}

        // Return to passive wake word when an audio/video overlay opens so that
        // media playback (YouTube, news streams, Reddit video) doesn't feed into STT.
        audioOverlayToken = SystemBus.shared.subscribe(OverlayOpenedEvent.self) { @MainActor [weak self] event in
            guard let self else { return }
            guard let kind = OverlayKind(rawValue: event.overlayKind), kind.containsAudio else { return }
            guard self.conversationalArmed || self.state.isListening else { return }
            self.conversationalArmed = false
            self.conversationalSessionActive = false
            self.state.conversationalArmedDiag = false
            self.returnToPassiveWake(reason: .stateTransition)
            self.state.log("conv", .info, "audio_overlay_opened kind=\(event.overlayKind) — returning to passive wake")
        }

        // Mac Brain HTTP server + Camera streaming
        cameraService.frameStore  = cameraFrameStore
        cameraService.diagnostics = cameraDiagnostics
        cameraService.checkPermission()
        // Run one-time migration from split-auth (brain token + Android token) to
        // unified gateway token. Safe to call every launch — no-ops after first run.
        GatewayMigration.migrateIfNeeded()
        if prefs.current.brainServerEnabled || prefs.current.cameraServerEnabled {
            startBrainServer()
        }

        // EntityFirstResolver — register all entity providers
        EntityFirstResolver.shared.registerDefaults(
            haAliasStore: homeAliases,
            haEntityRegistry: haEntityRegistry,
            getGitHubNotifications: { [weak self] in
                self?.githubClient?.lastFetchedNotifications ?? []
            }
        )

        // WorldStateAggregator — keeps AmbientWorldState current from SystemBus events
        worldStateAggregator = WorldStateAggregator(worldState: worldState)

        // ProactivityOrchestrator — wire callbacks and start delivery cycle
        orchestrator.onSpeak = { [weak self] text in
            Task { @MainActor in self?.speak(text) }
        }
        orchestrator.onSignal = { [weak self] signal in
            guard let self else { return }
            proactivity.ingest(signal, appState: state)
        }
        orchestrator.getAttentionContext = { [weak self] in
            guard let self else { return AttentionContext() }
            worldState.activeApp = ambientContext.context.activeApp.name
            worldState.isInConversation = conversation.isSessionActive
            worldState.emotionalTone = rollingMemory.emotionalTone
            worldState.conversationDepth = rollingMemory.recentTurns.count
            worldState.secondsSinceLastInteraction = timingEngine.secondsSinceUserSpeech
            return worldState.attentionContext(
                timingEngine: timingEngine,
                recentInterruptionCount: orchestrator.buildDefaultContext().recentInterruptionCount
            )
        }
        orchestrator.start()

        // Codebase intelligence bootstrap
        if prefs.current.selfKnowledgeEnabled {
            // Use explicit pref first; fall back to auto-discovery (searches ~/Desktop etc.
            // for JarvisMac.xcodeproj). Do NOT derive from Bundle.main.bundlePath — that
            // points into DerivedData during Debug builds, causing enrich() to mark every
            // feature as .partial.
            let root: URL
            if let explicit = prefs.current.projectDocsPath {
                root = URL(fileURLWithPath: explicit)
            } else {
                root = ProjectKnowledgeGraph.findProjectRoot() ?? URL(fileURLWithPath: "/")
            }
            ProjectKnowledgeGraph.shared.loadOrSeed(projectRoot: root)
            if prefs.current.codebaseIndexEnabled {
                CodebaseIndexer.shared.loadFromDisk()
            }
        }

        // Sprint N — persistent state bootstrap
        PersistentVisionContext.shared.loadFromDisk()
        BehaviourPatternEngine.shared.loadFromDisk()
        ReminderEscalationModel.shared.start()

        // Sprint N — JarvisRuntimeCoordinator wiring
        JarvisRuntimeCoordinator.shared.isTTSActive        = { [weak self] in self?.state.isSpeaking == true }
        JarvisRuntimeCoordinator.shared.isListeningActive  = { [weak self] in self?.state.isListening == true }
        JarvisRuntimeCoordinator.shared.isConversationActive = { [weak self] in self?.conversationalSessionActive == true }
        JarvisRuntimeCoordinator.shared.speakText          = { [weak self] text in self?.speak(text) }
        JarvisRuntimeCoordinator.shared.openOverlay        = { [weak self] kind in self?.openOverlay(kind) }

        // Phase 4 — wire DaemonAppBridge → Mac brain runtime (daemon-centric architecture)
        // DaemonAppBridge always connects to the daemon (JarvisBrainDaemon on port 8765).
        // When the daemon is not running, DaemonAppBridge retries with exponential backoff.
        DaemonAppBridge.shared.onTranscript = { [weak self] transcript, deviceId, platform, correlationId in
            guard let self else { return }
            let ctx = RemoteDeviceContext(
                deviceId: deviceId,
                platform: platform,
                deviceName: nil,
                capabilities: [],
                receivedAt: Date(),
                routeId: correlationId
            )
            Task { @MainActor in
                let response = await self.handleRemoteTranscript(transcript, context: ctx)
                await self.sendRemoteReply(response, to: ctx)
            }
        }
        DaemonAppBridge.shared.onAndroidEvent = { [weak self] command, data, deviceId in
            guard let self else { return }
            Task { @MainActor in
                self.androidEventReceiver?.receiveRawData(command: command, data: data, deviceId: deviceId)
            }
        }
        // Route execution.result frames to AndroidToolOrchestrator so pending
        // submitTool() calls resolve with the Android execution outcome.
        DaemonAppBridge.shared.onToolResult = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.androidToolOrchestrator.handleResult(data: data)
            }
        }
        DaemonAppBridge.shared.onPresenceUpdate = { [weak self] _ in
            CrossDeviceViewModel.shared.isDaemonConnected = true
        }
        DaemonAppBridge.shared.onCommPrompt = { payload in
            CommWatchdogCoordinator.shared.handle(payload)
        }
        DaemonAppBridge.shared.onHandoffReceived = { key, value in
            HandoffCoordinator.shared.receive(key: key, value: value)
        }
        DaemonAppBridge.shared.onClipboardUpdate = { text in
            HandoffCoordinator.shared.receiveClipboard(text)
        }
        DaemonAppBridge.shared.connect()
        RemoteActionExecutor.shared.wire(to: DaemonAppBridge.shared)

        androidToolOrchestrator.onDirectSend = { [weak self] envelope in
            // In daemon-centric architecture, tool requests route through DaemonAppBridge.
            // Direct broadcast via androidConnector is no longer supported.
            guard let self else { return }
            if let data = try? JSONSerialization.data(withJSONObject: envelope),
               let text = String(data: data, encoding: .utf8) {
                let envelope: [String: Any] = [
                    "id": UUID().uuidString,
                    "type": "execution.request",
                    "sourceDeviceId": "mac",
                    "sourcePlatform": "mac",
                    "target": ["type": "android"],
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "payload": envelope
                ]
                DaemonAppBridge.shared.send(envelope)
            }
        }

        state.log("app", .info, "Jarvis bootstrap complete")
        breadcrumb.write(subsystem: "app", action: "bootstrap_complete")
        context.setPhase(state.phase)
    }

    /// Registers the bundled documentation contributors with the shared
    /// `LivingDocumentationEngine`.  Each one closes over the dependencies
    /// it needs to read state at query time — no caches, no listeners.
    private func registerBuiltInDocumentationContributors() {
        let engine = LivingDocumentationEngine.shared
        engine.register(GettingStartedContributor())
        engine.register(ConversationsContributor())
        engine.register(ConversationalHelpContributor())
        engine.register(WakeAndListeningContributor(prefs: prefs))
        engine.register(OrbColorReferenceContributor())
        engine.register(AndroidContributor(
            diagnostics: { [weak self] in
                self?.androidBridge?.diagnostics ?? AndroidBridgeDiagnostics()
            }))
        engine.register(CallsAndMessagingContributor(
            diagnostics: { [weak self] in
                self?.androidBridge?.diagnostics ?? AndroidBridgeDiagnostics()
            }))
        engine.register(CameraVisionContributor(prefs: prefs))
        engine.register(AIProvidersContributor(prefs: prefs))
        engine.register(NewsContributor())
        engine.register(MemoryObsidianContributor(prefs: prefs))
        engine.register(PrivacyContributor(prefs: prefs))
        engine.register(MacSystemContributor())
        engine.register(ProactivityContributor())
        engine.register(SpatialInteractionContributor())
        engine.register(FocusAwarenessDocContributor(graphIndex: contextGraph))
        state.log("app", .info,
                  "living_docs_contributors_registered count=\(engine.registeredIds().count)")
    }

    /// Mirrors `StartupCoordinator` state into `AppState` so the Debug HUD
    /// and any observing UI can react without holding a direct reference to
    /// the coordinator.
    private func syncStartupDiagnostics() {
        state.startupPhase                = startupCoordinator.phase.rawValue
        state.startupReady                = startupCoordinator.isReady
        state.startupGracePeriodRemaining = startupCoordinator.gracePeriodRemaining
        state.startupProactivityGated     = startupCoordinator.proactivityGated
        state.startupQueuedSignalCount    = startupCoordinator.queuedSignalCount
        state.startupDiscardedSignalCount = startupCoordinator.discardedSignalCount
        state.firstProactiveAlertAt       = startupCoordinator.firstAlertAllowedAt
    }

    private func requestMicAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Emergency Stop

    /// Hard emergency stop fired by `JarvisHealthMonitor` when resident memory
    /// exceeds the threshold. Cancels all background loops, stops all providers,
    /// enables emergency safe mode in prefs (persisted), and shows a critical toast.
    ///
    /// The user must restart Jarvis after this fires. Re-enable subsystems one at
    /// a time in Settings > General to isolate the offending component.
    func forceEmergencyStop(reason: String) {
        breadcrumb.emergencyStop(reason: reason)
        state.log("health", .error,
                  "🚨 EMERGENCY STOP — \(reason). All subsystems stopping. Restart Jarvis.")

        // Cancel background task loops
        latencyPublishTask?.cancel(); latencyPublishTask = nil
        wakeWordWatchdogTask?.cancel(); wakeWordWatchdogTask = nil
        listeningTask?.cancel(); listeningTask = nil

        // Disarm conversational session before stopping audio — prevents the
        // persistent-session restart loop from firing during emergency teardown.
        conversationalArmed = false
        conversationalSessionActive = false
        state.conversationalArmedDiag = false
        state.persistentSessionActive = false
        conversationalArmTask?.cancel()
        conversationalTimeoutTask?.cancel()

        // Stop audio
        if wakeWord.isRunning { wakeWord.stop() }
        stopListening(reason: .stateTransition)
        tts.stop()

        // Stop camera
        camera.stopPreview()
        camera.frameTap = nil

        // Stop networking
        server.stop()
        tailscale.stop()

        // Stop all proactivity providers
        weatherProactivityProvider?.stop()
        calendarProactivityProvider?.stop()
        todoistProactivityProvider?.stop()
        githubProactivityProvider?.stop()
        haProactivityProvider?.stop()
        shopifyProactivityProvider?.stop()
        obsidianProactivityProvider?.stop()
        emailProactivityProvider?.stop()

        // Stop Mac Brain server
        brainServer?.stop()
        brainServer = nil

        // Stop news + timers
        newsScheduler.stop()
        timerService.stop()

        // Persist emergency mode so it survives restart
        prefs.update {
            $0.emergencySafeMode = true
        }

        showToast("🚨 Emergency stop — memory limit exceeded. Restart Jarvis.",
                  icon: "exclamationmark.triangle.fill")
    }

    // MARK: - Integration re-init

    /// Called from SettingsView after the Todoist token is updated so the
    /// stored client is replaced without requiring an app restart.
    func rebuildTodoist() {
        if let token = prefs.todoistAPIToken, !token.isEmpty {
            todoistClient = TodoistAPIClient(token: token)
            // Restart the proactivity provider with the new client
            todoistProactivityProvider?.stop()
            let prov = TodoistProactivityProvider(
                todoistClient: todoistClient!,
                engine: proactivity,
                appState: state,
                prefs: prefs)
            todoistProactivityProvider = prov
            prov.start()
        } else {
            todoistClient = nil
            todoistProactivityProvider?.stop()
            todoistProactivityProvider = nil
        }
    }

    // MARK: - Wake word

    func rebuildWakeWord() async {
        wakeWordWatchdogTask?.cancel()
        wakeObserverTask?.cancel()
        wakeWord.stop()

        let settings = prefs.current.wakeWord

        guard settings.enabled else {
            wakeWord = NoopWakeWord()
            state.wakeWordStatus = .unavailable("Disabled")
            return wireTriggers()
        }

        // 1. Try sherpa-onnx if a model directory is configured.
        if let modelDir = settings.modelIdentifier {
            let sherpa = SherpaWakeWordService(
                feedbackLog: wakeFeedback,
                preferredDeviceUID: { [weak self] in self?.audioDevices.preferredUID },
                keywordsFilePath: { [weak self] in self?.prefs.current.sherpaKeywordsFilePath },
                onLog: { [weak self] msg in
                    Task { @MainActor in self?.state.log("wake", .info, msg) }
                }
            )
            do {
                try sherpa.configure(settings)
                try sherpa.start()
                wakeWord = sherpa
                state.wakeWordStatus = .ready
                Log.app.info("wake word: sherpa armed (model: \(modelDir))")
                return wireTriggers()
            } catch {
                state.log("wake", .warn, "sherpa wake word failed: \(error.localizedDescription) — falling back to Apple")
            }
        }

        // 2. Fall back to Apple SFSpeechRecognizer-based wake detection.
        let apple = AppleWakeWordService { [weak self] msg in
            Task { @MainActor in self?.state.log("wake", .info, msg) }
        }
        do {
            try apple.configure(settings)
            try apple.start()
            wakeWord = apple
            state.wakeWordStatus = .ready
            Log.app.info("wake word: Apple always-listening armed")
        } catch {
            wakeWord = NoopWakeWord()
            state.wakeWordStatus = .failed(error.localizedDescription)
            state.log("wake", .warn, "apple wake word failed: \(error.localizedDescription)")
        }

        wireTriggers()
    }

    private func wireTriggers() {
        let triggers = wakeWord.triggers
        wakeObserverTask = Task { @MainActor [weak self] in
            for await event in triggers {
                guard let self else { return }
                self.handleWakeEvent(event)
            }
        }
        state.isWakeArmed = wakeWord.isRunning
        state.phase = wakeWord.isRunning ? .wakeListening : .idle
        // B6: restart watchdog whenever the wake-word service is (re)wired,
        // including initial bootstrap and runtime setting changes.
        startWakeWordWatchdog()
    }

    /// Restart wake word listening if it should be active (enabled in prefs,
    /// listening not muted, not already running, and the command recognizer
    /// isn't active). Wake intentionally runs during TTS so the user can
    /// say "Jarvis" to interrupt mid-speech.
    private func restartWakeWordIfNeeded() {
        guard state.listeningEnabled else { return }
        guard prefs.current.wakeWord.enabled else { return }
        guard !wakeWord.isRunning else { return }
        guard !state.isListening else { return }
        // Don't restart while in permanent-failure mode — a scheduled retry
        // will clear the flag and call us again after the backoff delay.
        guard !permanentSpeechFailureActive else { return }
        do {
            try wakeWord.start()
            state.isWakeArmed = true
            state.wakeWordStatus = .ready
            state.phase = .wakeListening
            Log.app.info("wake word: restarted (passive)")
        } catch {
            state.wakeWordStatus = .failed(error.localizedDescription)
            state.log("wake", .warn, "wake word restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - B6: Wake word watchdog

    /// Starts a background task that polls the wake-word service every 60 s.
    /// If the service has stopped unexpectedly (not due to the user muting or
    /// the STT being active), it restarts it automatically.
    private func startWakeWordWatchdog() {
        wakeWordWatchdogTask?.cancel()
        wakeWordWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 s
                guard let self, !Task.isCancelled else { return }

                // Don't watchdog while muted, disabled, or while the
                // command recogniser is actively running (wake legitimately
                // stops during STT).
                guard self.prefs.current.wakeWord.enabled else { continue }
                guard self.state.listeningEnabled else { continue }
                guard self.state.phase != .muted else { continue }
                guard !self.state.isListening else { continue }
                guard !self.permanentSpeechFailureActive else { continue }

                // NoopWakeWord is the silent fallback when both Sherpa and Apple
                // wake word failed. Don't try to restart it — it can never hear
                // anything and would falsely appear healthy after start().
                guard !(self.wakeWord is NoopWakeWord) else {
                    self.state.wakeWordStatus = .failed("No wake-word engine available")
                    continue
                }

                if !self.wakeWord.isRunning {
                    self.state.log("wake", .warn,
                        "watchdog: wake word not running — attempting restart")
                    do {
                        try self.wakeWord.start()
                        self.state.isWakeArmed = true
                        self.state.wakeWordStatus = .ready
                        self.state.phase = .wakeListening
                        self.state.log("wake", .info,
                            "watchdog: wake word restarted successfully")
                    } catch {
                        self.state.log("wake", .warn,
                            "watchdog: wake word restart failed — \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Always-on lifecycle

    /// Single source of truth for "the session ended — resume the passive
    /// resting state". Use this anywhere a transition that used to land in
    /// `.idle` is followed by a wake-word restart attempt. Idempotent.
    func returnToPassiveWake(reason: StopReason = .stateTransition) {
        let prevActual = state.listeningActualState.displayName
        state.listeningActualState = state.listeningEnabled ? .wakeWordListening : .idleListening
        state.pushLifecycleEvent(from: prevActual, to: state.listeningActualState.displayName,
                                 reason: "returnToPassiveWake:\(reason.rawValue)")
        // Diagnostic: log every return-to-passive transition so we can trace
        // who is calling this and whether conversational session is still live.
        state.log("conv", .info,
            "return_to_passive_wake reason=\(reason.rawValue) armed=\(conversationalArmed) sessionActive=\(conversationalSessionActive) speaking=\(state.isSpeaking) listeningEnabled=\(state.listeningEnabled)")
        // Make sure we're not still claiming to be listening / speaking.
        if state.isListening { state.isListening = false }
        state.lastStopReason = reason.rawValue

        // A14: After any real command session ends, summarise the recent
        // conversation turns into long-term memory (fire-and-forget).
        if let summariser = conversationSummariser {
            let sid = sessionId
            Task {
                await summariser.summariseRecentIfNeeded(sessionId: sid)
            }
        }

        if !state.listeningEnabled {
            // User muted us — keep audio off.
            if wakeWord.isRunning { wakeWord.stop(); state.isWakeArmed = false }
            if state.phase != .muted { state.phase = .muted }
            return
        }
        // Listening is enabled — resume the resting state IMMEDIATELY,
        // without ever passing through .idle (which would flicker in UI).
        if state.phase != .wakeListening { state.phase = .wakeListening }
        restartWakeWordIfNeeded()
    }

    /// Explicit user-initiated stop. After this, no wake-word listening
    /// and no STT until `enableListening()` is called.
    func disableListening(announce: Bool = true) {
        state.log("audio", .info, "listening_disabled — user-initiated mute")
        state.listeningEnabled = false
        conversationalSessionActive = false
        conversationalArmed = false
        state.conversationalArmedDiag = false
        state.persistentSessionActive = false
        conversationalArmTask?.cancel()
        conversationalArmTask = nil
        conversationalTimeoutTask?.cancel()
        conversationalTimeoutTask = nil
        clearPendingContext(resolution: "listening_disabled")
        if state.isListening { stopListening(reason: .userCancelled) }
        if wakeWord.isRunning { wakeWord.stop(); state.isWakeArmed = false }
        state.phase = .muted
        state.lastStopReason = StopReason.userCancelled.rawValue
        syncDesiredListeningMode()
        releaseListeningActivity()
        showToast("Listening disabled", icon: "moon.zzz.fill")
        if announce { speak(renderer.render(ResponseKey.listeningDisabled), critical: true) }
    }

    /// Resume passive wake listening after a user-initiated mute.
    func enableListening(announce: Bool = true) {
        state.log("audio", .info, "listening_enabled — user-initiated resume")
        state.listeningEnabled = true
        state.lastError = nil
        // Clear any permanent-failure backoff so the wake word can start fresh.
        permanentSpeechFailureActive = false
        dictationGuidanceShown = false
        if state.phase == .muted || state.phase == .idle || state.phase == .error {
            state.phase = .wakeListening
        }
        syncDesiredListeningMode()
        restartWakeWordIfNeeded()
        acquireListeningActivityIfWanted()
        showToast("Listening enabled", icon: "ear.fill")
        if announce { speak(renderer.render(ResponseKey.listeningEnabled), critical: true) }
    }

    /// Sync `state.listeningDesiredMode` from current preferences + flags.
    /// Call whenever listening preferences change. Read by the diagnostics panel.
    func syncDesiredListeningMode() {
        if !state.listeningEnabled {
            state.listeningDesiredMode = .disabled
        } else if prefs.current.conversationalFollowUpEnabled && prefs.current.persistentConversationEnabled {
            state.listeningDesiredMode = .conversation
        } else if prefs.current.persistentConversationEnabled {
            state.listeningDesiredMode = .persistent
        } else {
            state.listeningDesiredMode = .wakeWordOnly
        }
    }

    /// Watchdog kick: if wake should be running but isn't, restart it.
    /// Called from the 1 s periodic tick. Idempotent and rate-limited
    /// implicitly via `restartWakeWordIfNeeded`'s guards.
    func wakeWatchdogTick() {
        guard state.listeningEnabled else { return }
        guard prefs.current.wakeWord.enabled else { return }
        guard !state.isListening else { return }
        guard !state.isSpeaking else { return }
        // While in permanent-failure backoff the scheduled retry task handles
        // the re-arm — the 1 s watchdog must not race against that window.
        guard !permanentSpeechFailureActive else { return }

        // ── Conversational session watchdog ───────────────────────────────────
        // If the 10-minute armed window is still active but we somehow ended up
        // in passive-wake state with no STT running (race between endConversational-
        // Session's async restart Task and returnToPassiveWake), restart STT here
        // rather than restarting wake word.  Only fires when wake is NOT running
        // (i.e. we're in a brief gap, not during normal passive-wake-word state).
        if conversationalArmed,
           prefs.current.conversationalFollowUpEnabled,
           prefs.current.persistentConversationEnabled,
           !wakeWord.isRunning,
           state.phase == .wakeListening {
            state.conversationalRestarts += 1
            state.persistentSessionActive = true
            state.log("conv", .warn,
                "conv_watchdog — armed+passive-wake gap, restart #\(state.conversationalRestarts)")
            startConversationalListening()
            return
        }

        guard !wakeWord.isRunning else { return }

        // Phases where wake legitimately doesn't run.
        switch state.phase {
        case .listening, .thinking, .speaking, .bargedIn,
             .conversationalListening, .awaitingResponse, .muted:
            return
        case .idle, .wakeListening, .error:
            break
        }
        state.wakeWatchdogRestarts += 1
        state.lastWatchdogRecoveryAt = Date()
        let reason = "phase=\(state.phase.rawValue)"
        state.lastWatchdogReason = reason
        state.log("wake", .warn,
            "wake_watchdog_restart count=\(state.wakeWatchdogRestarts) \(reason)")
        state.pushLifecycleEvent(from: state.listeningActualState.displayName,
                                 to: "wakeWordListening",
                                 reason: "watchdog:\(reason)")
        restartWakeWordIfNeeded()
    }

    // MARK: - App Nap suppression

    private var listeningActivity: NSObjectProtocol?

    /// Hold a `ProcessInfo` activity assertion while listening so macOS
    /// doesn't App-Nap throttle the audio pipeline. The token is released
    /// when listening is disabled.
    func acquireListeningActivityIfWanted() {
        guard state.keepAwakeEnabled else { return }
        guard listeningActivity == nil else { return }
        listeningActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Jarvis is in passive wake listening."
        )
        state.log("system", .info, "power_activity_acquired")
    }

    func releaseListeningActivity() {
        if let token = listeningActivity {
            ProcessInfo.processInfo.endActivity(token)
            listeningActivity = nil
            state.log("system", .info, "power_activity_released")
        }
    }

    // MARK: - Conversational session

    /// Arms the persistent 10-minute conversational window.  Resets the
    /// disarm timer on every wake event and every user speech turn so the
    /// window extends naturally as long as the conversation continues.
    private func armConversationalMode() {
        conversationalArmed = true
        conversationalSessionActive = true
        state.conversationalArmedDiag = true
        // Also arm the ConversationRuntime so it can publish events + own its timer.
        conversation.arm()
        conversationalArmTask?.cancel()
        conversationalArmTask = Task { @MainActor [weak self] in
            // 10-minute inactivity timeout for the persistent window.
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.conversationalArmed = false
            self.conversationalSessionActive = false
            self.state.conversationalArmedDiag = false
            self.state.persistentSessionActive = false
            self.state.log("conv", .info, "conversational_armed_expired — 10 min elapsed")
        }
    }

    /// Called after TTS finishes when `conversationalSessionActive == true`.
    /// Immediately starts command recognizer with a silence timeout.
    func startConversationalListening() {
        guard !state.isListening else { return }
        // ── Media-playback listening-pause rule ──────────────────────────
        // While a live news / video stream is playing, we must NOT
        // continuously transcribe — the TV audio would constantly trigger
        // false commands.  Wake word remains armed in passive mode, so
        // the user can still interrupt by saying "Jarvis".
        if state.mediaPlaybackState.isPlaying {
            state.log("conv", .info,
                "conv_start_suppressed reason=media_playing channel=\(state.mediaPlaybackState.displayLabel)")
            return
        }
        state.log("conv", .info,
            "conversational window open timeout=\(Int(prefs.current.conversationalTimeoutSeconds))s armed=\(conversationalArmed) sessionActive=\(conversationalSessionActive)")
        startListening(reason: .conversationalFollowup)
        // Override .listening → .conversationalListening so UI shows follow-up state.
        if state.isListening { state.phase = .conversationalListening }
        scheduleConversationalTimeout()
    }

    func scheduleConversationalTimeout() {
        conversationalTimeoutTask?.cancel()
        let seconds = prefs.current.conversationalTimeoutSeconds
        conversationalTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.state.phase == .conversationalListening
                  || self.state.isListening else { return }
            self.endConversationalSession()
        }
    }

    /// Ends the current conversational STT window.
    ///
    /// - Parameter permanent: When `true`, the session is truly over (user said
    ///   "stop listening" / app closing / mic failure). When `false` (the default),
    ///   this is just a silence timeout — restart STT immediately if the session
    ///   is still armed and `persistentConversationEnabled` is set.
    func endConversationalSession(permanent: Bool = false) {
        conversationalTimeoutTask?.cancel()
        conversationalTimeoutTask = nil

        if permanent {
            conversationalSessionActive = false
            state.persistentSessionActive = false
            state.log("conv", .info, "conversational session ended permanently")
            stopListening(reason: .userCancelled)
            return
        }

        // Silence timeout — stop current STT window.
        stopListening(reason: .silenceTimeout)

        // If TTS is currently playing, rewireSpeakingObserver already owns the
        // post-speech restart.  Do NOT kill conversationalSessionActive here —
        // that would permanently end the session before the user even hears
        // Jarvis's response.  Just let the speaking path handle restart.
        if state.isSpeaking {
            state.log("conv", .info,
                "silence_timeout fired during TTS — session kept alive, rewireSpeakingObserver handles restart")
            return
        }

        // Restart STT immediately if the 10-minute armed window is still active
        // and persistent-conversation mode is enabled.  This is what keeps Jarvis
        // listening indefinitely: silence is just a pause, not a session kill.
        guard conversationalArmed,
              prefs.current.conversationalFollowUpEnabled,
              prefs.current.persistentConversationEnabled,
              state.listeningEnabled else {
            conversationalSessionActive = false
            state.persistentSessionActive = false
            state.log("conv", .info, "conversational session ended — returning to wake word")
            return
        }

        state.conversationalRestarts += 1
        state.persistentSessionActive = true
        state.log("conv", .info,
            "silence timeout — restarting STT (persistent, restart #\(state.conversationalRestarts))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms audio settle
            guard let self,
                  self.conversationalArmed,
                  !self.state.isListening else { return }
            self.startConversationalListening()
        }
    }

    func recordWakeFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?) {
        wakeWord.recordFeedback(feedback, for: event)
        state.log("wake", .info, "feedback: \(feedback.rawValue)")
    }

    private func handleWakeEvent(_ event: WakeWordEvent) {
        latency.mark(.wakeDetect)
        state.lastWakeEvent = event
        state.recentWakeScores.append(event.confidence)
        // Begin execution trace — correlationID threads through transcript → intent → TTS.
        let corrID = ExecutionTracer.shared.begin(label: "wake:\(event.keyword)")
        ExecutionTracer.shared.addStep("wake_detected",
                                       detail: "\(event.keyword) @ \(String(format: "%.2f", event.confidence))",
                                       runtimeID: "audio")
        // Publish wake event so subscribers (diagnostics, EventStore) see it.
        SystemBus.shared.publish(WakeDetectedEvent(keyword: event.keyword,
                                                    confidence: event.confidence,
                                                    correlationID: corrID))
        if state.recentWakeScores.count > 20 {
            state.recentWakeScores.removeFirst(state.recentWakeScores.count - 20)
        }
        state.log("wake", .info,
                  "detect \(event.keyword) @ \(String(format: "%.2f", event.confidence)) — wake-engine teardown already done")
        context.recordWake(event)

        // Audible acknowledgement — short native chime via NSSound.
        // Plays through the system output device; does not touch the mic.
        playWakeChime()

        if state.isSpeaking {
            // Barge-in: user says "Jarvis" while Jarvis is speaking.
            latency.mark(.bargeIn)
            state.lastBargeInReason = "wake word: \(event.keyword)"
            state.phase = .bargedIn
            tts.stop()
            // Keep conversationalSessionActive — barge-in interrupts speech but
            // does NOT end the conversational session. The new wake event will
            // call armConversationalMode() and start fresh STT immediately after.
            state.log("audio", .info, "barge-in via wake word during TTS")
            state.pushTimeline(TimelineEvent(timestamp: event.timestamp,
                                             symbol: "exclamationmark.bubble.fill",
                                             title: "Interrupted",
                                             detail: "wake word: \(event.keyword)"))
        } else {
            state.pushTimeline(TimelineEvent(timestamp: event.timestamp,
                                             symbol: "waveform.badge.mic",
                                             title: "Wake",
                                             detail: "\(event.keyword) · \(String(format: "%.2f", event.confidence))"))
        }

        // Cancel any existing conversational timeout — wake word resets the session.
        conversationalTimeoutTask?.cancel()

        // Settle delay: AppleWakeWordService has already torn down its
        // AVAudioEngine on the main queue, but CoreAudio's HAL needs a few
        // tens of ms to fully release the input device before STT's engine
        // can grab it without producing zero-byte buffers. Without this
        // delay, SFSpeechRecognitionTask hits "no audio" errors within
        // ~100 ms and the listening session dies before the user can speak.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000) // 60 ms
            guard let self else { return }
            self.state.log("audio", .info, "post-wake settle complete — starting STT")
            // Arm the 10-minute conversational window starting from this wake.
            self.armConversationalMode()
            self.startListening(reason: .wakeWord)
        }
    }

    /// Normalize for logging only — mirrors what IntentRouter does
    /// internally so the trace logs show the post-normalization text.
    private static func normalizedForLog(_ text: String) -> String {
        var t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        for wake in ["jarvis,", "jarvis.", "jarvis", "hey jarvis", "ok jarvis"] {
            if t.hasPrefix(wake + " ") { t = String(t.dropFirst(wake.count + 1)); break }
        }
        for filler in ["please ", "can you ", "could you ", "would you "] {
            if t.hasPrefix(filler) { t = String(t.dropFirst(filler.count)); break }
        }
        return t
    }

    /// Short audible acknowledgement on wake. Plays through the system
    /// output device — does not touch the input mic, does not interrupt
    /// TTS (we already called `tts.stop()` upstream if applicable).
    private func playWakeChime() {
        // "Tink" is the shortest built-in system sound (~90 ms). Falls
        // back to NSBeep if the named sound is unavailable.
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.volume = 0.6
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Apple's SFSpeechRecognizer surfaces a small set of error descriptions
    /// that mean "the user must change a System Setting before this will
    /// ever work" — most commonly when macOS Dictation is disabled (which
    /// also disables the on-device speech model).
    private static func isPermanentSpeechFailure(_ desc: String) -> Bool {
        let lower = desc.lowercased()
        return lower.contains("dictation are disabled")
            || lower.contains("dictation is disabled")
            || lower.contains("siri and dictation")
            || lower.contains("speech recognition is not authorized")
    }

    /// Returns true when an STT task error is the "no speech detected" class —
    /// a harmless Apple Speech Framework timeout that happens in quiet periods.
    /// These must NOT trigger memory writes, summarisation, or error UI.
    /// The session's protected-window restart logic already handles recovery.
    private static func isNoSpeechError(_ desc: String) -> Bool {
        let lower = desc.lowercased()
        return lower.contains("no speech")
            || lower.contains("no audio")
            || lower.hasPrefix("the operation couldn")   // "couldn't complete" no-speech path
            || lower.contains("error 1110")              // kAFAssistantErrorDomain 1110
            || lower.contains("code=1110")
    }

    /// One-shot guard so we don't speak the same guidance every time the
    /// user says "Jarvis" while Dictation is off.
    private var dictationGuidanceShown = false

    /// Stop the listening loop, surface a clear message, open the right
    /// System Settings pane, and enter permanent-failure backoff mode.
    ///
    /// Backoff prevents an infinite loop where wake fires → STT hits the same
    /// system error → wake restarts → repeat. A 45-second retry window gives
    /// the user time to fix the macOS setting before we try again automatically.
    private func handlePermanentSpeechFailure(session: ListeningSession, desc: String) {
        state.log("speech", .error,
            "permanent_speech_failure session=\(session.shortID) restarts=\(session.restartCount) — \(desc)")

        // Cancel the active session so the protected-window restart in the
        // listening task's post-loop sees `wasCancelled == true` and exits
        // to idle instead of looping forever.
        session.isCancelled = true
        session.lastStopReason = .recognizerError
        state.lastStopReason = StopReason.recognizerError.rawValue

        let userMsg = "macOS Dictation is disabled. Open System Settings → Keyboard → Dictation, turn it on, then say Jarvis again."
        state.lastError = userMsg

        // Arm the permanent-failure guard BEFORE stopping wake so that
        // `returnToPassiveWake` (called after the stream ends) and the
        // 1 s watchdog both see the flag and skip the restart.
        permanentSpeechFailureActive = true
        let prevActualForFailure = state.listeningActualState.displayName
        state.listeningActualState = .unavailable(reason: "Dictation disabled")
        state.pushLifecycleEvent(from: prevActualForFailure,
                                 to: state.listeningActualState.displayName,
                                 reason: "permanent_speech_failure")

        if wakeWord.isRunning {
            wakeWord.stop()
            state.isWakeArmed = false
            state.wakeWordStatus = .failed("macOS Dictation disabled")
            state.log("wake", .warn, "wake word disarmed — permanent failure backoff active")
        }

        if !dictationGuidanceShown {
            dictationGuidanceShown = true
            showToast("Enable macOS Dictation", icon: "exclamationmark.bubble.fill")
            speak(renderer.render(ResponseKey.dictationNeeded), critical: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.Dictation-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }

        // Schedule a timed retry so the system self-heals once the user has
        // fixed the setting, without manual intervention.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000) // 45 s
            guard let self, !Task.isCancelled else { return }
            self.permanentSpeechFailureActive = false
            self.state.wakeWordStatus = .ready
            let prevActualForRetry = self.state.listeningActualState.displayName
            self.state.listeningActualState = .idleListening
            self.state.pushLifecycleEvent(from: prevActualForRetry, to: "Idle",
                                          reason: "permanent_failure_retry_45s")
            self.state.log("wake", .info, "permanent_failure_retry — clearing backoff after 45 s")
            self.restartWakeWordIfNeeded()
        }
    }

    // MARK: - Listening (push-to-talk OR wake-triggered)

    var isListening: Bool { state.isListening }

    func toggleListening() {
        if isListening { stopListening() } else { startListening() }
    }

    func startListening(reason: ListeningSession.Reason = .pushToTalk,
                        continuingSession: ListeningSession? = nil) {
        guard !state.isListening else {
            state.log("audio", .info,
                "startListening ignored — already listening (session=\(activeSession?.shortID ?? "-"))")
            return
        }
        let usingWhisper = (prefs.current.speechEngine == .whisper && whisperRecognizer != nil)
        // Check live authorization rather than potentially-stale cached status.
        if !usingWhisper {
            let liveAuth = SFSpeechRecognizer.authorizationStatus()
            if liveAuth == .authorized && !state.speechStatus.isHealthy {
                state.speechStatus = .ready
            }
            if liveAuth != .authorized {
                state.log("audio", .warn, "Cannot start listening — speech not authorized (status: \(liveAuth.rawValue))")
                return
            }
        }
        guard state.microphoneStatus.isHealthy else {
            state.log("audio", .warn, "Cannot start listening — microphone not ready")
            return
        }
        if state.isSpeaking { tts.stop() }
        // Defensive: if wake somehow still claims running, tear it down.
        // The handleWakeEvent path stops wake on its own thread before we
        // get here, so under normal flow this is a no-op.
        if wakeWord.isRunning {
            state.log("audio", .info, "startListening: wake still running, stopping")
            wakeWord.stop()
            state.isWakeArmed = false
        }
        // Clear any previous error state before a fresh attempt.
        state.lastError = nil
        if state.phase == .error { state.phase = .idle }

        // Create or reuse listening session (restart within min window reuses same session).
        let session = continuingSession ?? ListeningSession.make(reason: reason)
        if continuingSession != nil { session.restartCount += 1 }
        activeSession = session
        state.listeningReason = reason.rawValue
        state.listeningSessionShortID = session.shortID
        state.listeningRestartCount = session.restartCount
        state.listeningSawAudioBuffer = session.hasReceivedAudioBuffer
        state.listeningMinRemainingMs = Int(session.minListenRemainingSeconds * 1000)
        let attempt = session.restartCount
        let prevActual = state.listeningActualState.displayName
        state.listeningActualState = .activelyListening
        state.pushLifecycleEvent(from: prevActual, to: "activelyListening",
                                 reason: reason.rawValue)
        state.log("audio", .info,
            "startListening session=\(session.shortID) reason=\(reason.rawValue) attempt=\(attempt) min_remaining_ms=\(state.listeningMinRemainingMs)")
        SystemBus.shared.publish(ListeningStartedEvent(reason: reason.rawValue,
                                                        correlationID: ExecutionTracer.shared.activeCorrelationID))
        ExecutionTracer.shared.addStep("listening_started", detail: reason.rawValue, runtimeID: "audio")

        // Engine selection (re-read each session so /settings changes apply without a relaunch).
        if let w = whisperRecognizer, prefs.current.speechEngine == .whisper {
            recognizer = w
        } else {
            recognizer = appleRecognizer
        }
        state.speechEngine = recognizer.engine
        state.isOffline = recognizer.isOffline

        // Wire onFirstBuffer to mark the session and aid debugging — only
        // valid for the Apple recognizer (Whisper has its own VAD path).
        appleRecognizer.onFirstBuffer = { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                guard self.activeSession?.id == session.id else { return }
                if !session.hasReceivedAudioBuffer {
                    session.hasReceivedAudioBuffer = true
                    self.state.listeningSawAudioBuffer = true
                    self.state.log("audio", .info,
                        "audio_buffer_first session=\(session.shortID) mic=\(self.state.activeMicrophoneName ?? "?")")
                }
            }
        }
        appleRecognizer.onTaskError = { [weak self, weak session] desc in
            // Called from main queue (see AppleSpeechRecognizer error path);
            // assume @MainActor isolation so we can mutate session + state
            // synchronously BEFORE the subsequent stop() finishes the stream.
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                guard self.activeSession?.id == session.id else { return }

                // "No speech detected" is a normal, harmless Apple STT timeout —
                // not an error worth surfacing. Log at debug level and increment
                // the diagnostic counter; the post-loop protected-window logic
                // already handles the session restart correctly.
                if Self.isNoSpeechError(desc) {
                    self.state.noSpeechIgnoredCount += 1
                    self.state.log("speech", .debug,
                        "stt_no_speech_ignored session=\(session.shortID) count=\(self.state.noSpeechIgnoredCount)")
                    return
                }

                self.state.log("speech", .warn,
                    "stt_task_error session=\(session.shortID) desc=\(desc)")
                if Self.isPermanentSpeechFailure(desc) {
                    self.handlePermanentSpeechFailure(session: session, desc: desc)
                }
            }
        }

        state.partialTranscript = ""
        state.isListening = true
        state.phase = .listening
        context.setPhase(.listening)
        latency.mark(.sttStart)

        do {
            let stream = try recognizer.start(preferredDeviceUID: audioDevices.preferredUID)
            let routedName = CoreAudioInputRouter.audioDeviceID(forUID: audioDevices.preferredUID ?? "")
                .flatMap(CoreAudioInputRouter.nameOf)
            if let routedName { state.activeMicrophoneName = routedName }
            state.micRoutingStatus = .ready
            state.log("audio", .info,
                "stt_engine_started session=\(session.shortID) mic_uid=\(audioDevices.preferredUID ?? "default") mic_name=\(routedName ?? "?")")

            let sessionSnapshot = session

            listeningTask = Task { @MainActor [weak self] in
                var sawPartial = false
                // Set to true when a partial-transcript early-exit fires so
                // the post-loop soft-final fallback knows not to re-route.
                var handledByPartial = false
                // Soft-final timer: Apple's on-device STT sometimes never
                // fires `isFinal=true` for short commands. Each non-empty
                // partial resets a 1.4 s timer; if it fires, we call
                // `recognizer.stop()` to force end-of-audio. The post-loop
                // then routes the captured partial as the command.
                var softFinalTask: Task<Void, Never>?
                func armSoftFinal(after seconds: Double, _ self0: JarvisController) {
                    softFinalTask?.cancel()
                    softFinalTask = Task { @MainActor [weak self0] in
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        guard let s = self0, !Task.isCancelled else { return }
                        guard s.activeSession?.id == sessionSnapshot.id else { return }
                        guard !sessionSnapshot.hasReceivedNonEmptyFinal else { return }
                        let pt = s.state.partialTranscript
                            .trimmingCharacters(in: .whitespaces)
                        s.state.log("audio", .info,
                            "soft_final_fire session=\(sessionSnapshot.shortID) partial=\"\(pt.prefix(60))\" — forcing recognizer.stop()")
                        s.recognizer.stop()
                    }
                }

                for await t in stream {
                    guard let self else { return }
                    self.state.partialTranscript = t.text
                    self.context.recordTranscript(t.text, final: t.isFinal)
                    if !t.text.isEmpty {
                        sessionSnapshot.hasReceivedPartialTranscript = true
                    }
                    if !t.text.isEmpty && self.state.phase == .conversationalListening {
                        self.scheduleConversationalTimeout()
                    }
                    if !sawPartial && !t.text.isEmpty {
                        sawPartial = true
                        self.latency.mark(.sttFirstPartial)
                        self.latency.measure(from: .sttStart, to: .sttFirstPartial, recordAs: .sttFirstPartial)
                        self.state.log("audio", .info,
                            "stt_first_partial session=\(sessionSnapshot.shortID)")
                        // STT is clearly working again — clear any permanent-failure
                        // backoff and re-arm dictation guidance for future failures.
                        self.dictationGuidanceShown = false
                        if self.permanentSpeechFailureActive {
                            self.permanentSpeechFailureActive = false
                            self.state.log("wake", .info, "permanent_failure_cleared — speech active")
                        }
                    }
                    // Reset soft-final timer on every non-empty partial.
                    if !t.text.isEmpty && !t.isFinal {
                        armSoftFinal(after: 1.4, self)
                    }

                    // ── B3: Early-partial routing ─────────────────────────
                    // On a non-final partial with ≥ 3 words, try two fast
                    // paths before waiting for a true isFinal. This saves
                    // 300–800 ms on short, deterministic commands.
                    if !t.isFinal && !t.text.isEmpty && !handledByPartial {
                        let wordCount = t.text.split(separator: " ").count
                        if wordCount >= 3 {
                            let normalized = TranscriptNormalizer.normalize(t.text)

                            // Path A: FastResponseRouter — deterministic
                            // conversational answers with high confidence.
                            if let fast = self.fastRouter.respond(
                                normalized: normalized,
                                prefs: self.prefs.current,
                                state: self.state,
                                llmMode: self.llmRouter.mode,
                                capabilities: self.capabilities
                            ), fast.confidence >= 0.92 {
                                handledByPartial = true
                                sessionSnapshot.hasReceivedNonEmptyFinal = true
                                sessionSnapshot.lastStopReason = .stateTransition
                                softFinalTask?.cancel()
                                self.recognizer.stop()
                                self.latency.mark(.fastRoute)
                                self.state.log("audio", .info,
                                    "partial_early_exit_fast session=\(sessionSnapshot.shortID) conf=\(String(format: "%.2f", fast.confidence)) words=\(wordCount)")
                                self.speak(fast.text)
                                break
                            }

                            // Path B: Exact phrase-store match on a set of
                            // instant, parameter-free intents (time, date,
                            // stop talking, hearing check). Entity-bearing
                            // commands are excluded — they need the full
                            // transcript to resolve the entity name.
                            if let match = self.phraseMatcher.match(
                                normalizedInput: normalized,
                                definitions: self.phraseStore.definitions
                            ), match.matchType == .exact,
                               let intent = IntentMapping.intent(for: match.commandId) {
                                let isInstant: Bool
                                switch intent {
                                case .tellTime, .tellDate, .stopTalking,
                                     .canYouHearMe, .areYouListening:
                                    isInstant = true
                                default:
                                    isInstant = false
                                }
                                if isInstant {
                                    handledByPartial = true
                                    sessionSnapshot.hasReceivedNonEmptyFinal = true
                                    sessionSnapshot.lastStopReason = .stateTransition
                                    softFinalTask?.cancel()
                                    self.recognizer.stop()
                                    self.state.lastFinalTranscript = t.text
                                    self.state.log("audio", .info,
                                        "partial_early_exit_phrase session=\(sessionSnapshot.shortID) cmd=\(match.commandId) words=\(wordCount)")
                                    await self.execute(intent)
                                    break
                                }
                            }
                        }
                    }
                    // ── end B3 ────────────────────────────────────────────

                    if t.isFinal {
                        softFinalTask?.cancel()
                        self.latency.mark(.sttFinal)
                        self.latency.measure(from: .sttStart, to: .sttFinal, recordAs: .sttFinal)
                        let trimmed = t.text.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            // Empty final — caller below handles within-window
                            // restart based on the session's protection state.
                            sessionSnapshot.lastStopReason = .emptyFinal
                            self.state.log("audio", .info,
                                "stt_empty_final session=\(sessionSnapshot.shortID)")
                            break
                        }
                        sessionSnapshot.hasReceivedNonEmptyFinal = true
                        sessionSnapshot.lastStopReason = .stateTransition
                        self.state.lastFinalTranscript = trimmed
                        self.state.log("audio", .info,
                            "stt_nonempty_final session=\(sessionSnapshot.shortID) len=\(trimmed.count)")
                        await self.handleTranscript(trimmed)
                    }
                }
                softFinalTask?.cancel()
                guard let self else { return }

                // Decide what to do now that the stream has ended.
                let isCurrent = (self.activeSession?.id == sessionSnapshot.id)
                let withinEmptyWindow  = Date() < sessionSnapshot.allowEmptyFinalAfter
                let withinSilenceWindow = Date() < sessionSnapshot.allowSilenceTimeoutAfter
                let withinProtected = withinEmptyWindow || withinSilenceWindow
                let wasCancelled = sessionSnapshot.isCancelled

                self.state.isListening = false

                // SOFT-FINAL FALLBACK: if no true isFinal fired but we have
                // a non-empty partial, route it. Apple's on-device STT
                // sometimes never emits isFinal on short commands.
                if isCurrent && !wasCancelled && !sessionSnapshot.hasReceivedNonEmptyFinal {
                    let pt = self.state.partialTranscript.trimmingCharacters(in: .whitespaces)
                    if !pt.isEmpty {
                        sessionSnapshot.hasReceivedNonEmptyFinal = true
                        self.state.lastFinalTranscript = pt
                        self.latency.mark(.sttFinal)
                        self.state.log("audio", .info,
                            "soft_final_route session=\(sessionSnapshot.shortID) text=\"\(pt)\" — no true isFinal seen")
                        await self.handleTranscript(pt)
                        // We routed a command — clear the session and
                        // restart wake. Don't fall into the protected
                        // restart path; that's for empty/erroring sessions.
                        if self.activeSession?.id == sessionSnapshot.id {
                            self.activeSession = nil
                        }
                        if !self.state.isSpeaking
                           && self.state.phase != .conversationalListening
                           && self.state.phase != .speaking {
                            self.restartWakeWordIfNeeded()
                        }
                        return
                    }
                }

                let gotRealContent = sessionSnapshot.hasReceivedNonEmptyFinal
                self.state.log("audio", .info,
                    "stt_stream_end session=\(sessionSnapshot.shortID) current=\(isCurrent) cancelled=\(wasCancelled) real_final=\(gotRealContent) protected=\(withinProtected) audio_buf=\(sessionSnapshot.hasReceivedAudioBuffer) partials=\(sessionSnapshot.hasReceivedPartialTranscript) last_stop=\(sessionSnapshot.lastStopReason.rawValue) restarts=\(sessionSnapshot.restartCount)")

                // Restart within protected window if:
                // - we are still the current session,
                // - we weren't explicitly cancelled,
                // - we haven't received a real (non-empty) final yet, and
                // - we're still inside the protected window.
                if isCurrent && !wasCancelled && !gotRealContent && withinProtected {
                    self.state.log("audio", .info,
                        "stt_restart_protected session=\(sessionSnapshot.shortID) reason=\(sessionSnapshot.lastStopReason.rawValue)")
                    self.state.lastStopReason = sessionSnapshot.lastStopReason.rawValue
                    self.startListening(reason: sessionSnapshot.reason,
                                        continuingSession: sessionSnapshot)
                    return
                }

                // Past protected window with no audio at all → tell the user the mic never armed.
                if isCurrent && !sessionSnapshot.hasReceivedAudioBuffer && !wasCancelled {
                    let micName = self.state.activeMicrophoneName ?? "selected microphone"
                    let msg = "I detected the wake word but couldn't hear input from \(micName)."
                    self.state.log("audio", .error, "no_audio_buffer session=\(sessionSnapshot.shortID) — \(msg)")
                    self.state.lastError = msg
                    self.state.lastStopReason = StopReason.recognizerError.rawValue
                }

                // Past protected window, no command — graceful silence timeout.
                if isCurrent && !gotRealContent && !wasCancelled
                   && sessionSnapshot.hasReceivedAudioBuffer {
                    self.state.log("audio", .info,
                        "silence_timeout session=\(sessionSnapshot.shortID)")
                    self.state.lastStopReason = StopReason.silenceTimeout.rawValue
                }

                // Clear active session if we owned it.
                if isCurrent { self.activeSession = nil }

                // Resume listening after the STT session ends.
                // If the conversational session is armed and no TTS was just
                // queued (detected via lastSpeakCalledAt), restart STT directly
                // so overlay-open commands and other non-TTS intents don't drop
                // the conversation. If TTS is pending, rewireSpeakingObserver
                // handles the restart after speech finishes.
                if !self.state.isSpeaking
                   && self.state.phase != .conversationalListening {
                    let justSpoke = self.lastSpeakCalledAt.timeIntervalSinceNow > -0.5
                    if justSpoke {
                        // TTS was just queued from execute() — rewireSpeakingObserver
                        // will restart STT after speech finishes.  Do NOT return to
                        // passive wake here; that creates a visible state flicker and
                        // starts the wake word unnecessarily while TTS is playing.
                        self.state.log("conv", .debug,
                            "post-loop: TTS queued, rewireSpeakingObserver owns restart — no returnToPassiveWake")
                    } else if self.conversationalArmed,
                       self.prefs.current.conversationalFollowUpEnabled,
                       self.prefs.current.persistentConversationEnabled,
                       self.state.listeningEnabled {
                        // Non-TTS command finished (overlay, clipboard, etc.) —
                        // restart STT immediately to keep the session alive.
                        self.state.conversationalRestarts += 1
                        self.state.persistentSessionActive = true
                        self.state.log("conv", .info,
                            "post-command STT restart (armed, no TTS) #\(self.state.conversationalRestarts)")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms settle
                            guard let self,
                                  self.conversationalArmed,
                                  !self.state.isListening else { return }
                            self.startConversationalListening()
                        }
                    } else {
                        self.returnToPassiveWake(
                            reason: StopReason(rawValue: sessionSnapshot.lastStopReason.rawValue) ?? .stateTransition)
                    }
                }
            }
        } catch {
            // Engine-start failure during the wake handoff is normally a
            // race against CoreAudio HAL teardown. If we're still inside
            // the protected window, retry instead of surfacing the error.
            state.isListening = false
            let msg = error.localizedDescription
            session.lastStopReason = .recognizerError
            state.log("speech", .error,
                "stt_engine_start_failed session=\(session.shortID) attempt=\(session.restartCount) error=\(msg)")

            if Date() < session.minimumListenUntil && !session.isCancelled {
                // Brief backoff, then retry within protected window.
                Task { @MainActor [weak self, weak session] in
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80 ms
                    guard let self, let session,
                          self.activeSession?.id == session.id,
                          !session.isCancelled else { return }
                    self.state.log("audio", .info,
                        "stt_engine_retry session=\(session.shortID)")
                    self.startListening(reason: session.reason, continuingSession: session)
                }
                return
            }

            activeSession = nil
            state.lastError = msg
            state.lastStopReason = StopReason.recognizerError.rawValue
            state.phase = .error
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.state.phase == .error else { return }
                self.state.lastError = nil
                // Recoverable error → return to passive wake, not dead idle.
                self.returnToPassiveWake(reason: .recognizerError)
            }
            if recognizer.engine == .whisper {
                recognizer = appleRecognizer
                state.speechEngine = .apple
                state.isOffline = appleRecognizer.isOffline
                state.log("speech", .warn, "Whisper failed, fell back to Apple Speech. Press PTT to try again.")
            }
        }
    }

    /// Stop listening for any reason. `reason` is recorded for diagnostics.
    /// Marking the active session cancelled prevents the protected-window
    /// restart from re-arming after `recognizer.stop()` ends the stream.
    func stopListening(reason: StopReason = .userCancelled) {
        if let s = activeSession {
            s.isCancelled = true
            s.lastStopReason = reason
            state.log("audio", .info,
                "stopListening session=\(s.shortID) reason=\(reason.rawValue)")
        } else {
            state.log("audio", .info, "stopListening (no active session) reason=\(reason.rawValue)")
        }
        let prevActual = state.listeningActualState.displayName
        state.listeningActualState = .wakeWordListening
        state.pushLifecycleEvent(from: prevActual, to: "wakeWordListening",
                                 reason: reason.rawValue)
        SystemBus.shared.publish(ListeningStoppedEvent(reason: reason.rawValue,
                                                        correlationID: ExecutionTracer.shared.activeCorrelationID))
        activeSession = nil
        conversationalTimeoutTask?.cancel()
        conversationalTimeoutTask = nil
        // NOTE: conversationalSessionActive is intentionally NOT cleared here.
        // Only endConversationalSession(permanent:true) or the 10-minute arm
        // timeout may end the persistent conversational session. Clearing it
        // here caused the session to die permanently on every silence timeout,
        // barge-in, or overlay command — the P0 listening lifecycle regression.
        recognizer.stop()
        listeningTask?.cancel()
        listeningTask = nil
        state.isListening = false
        state.lastStopReason = reason.rawValue
        // Session ended → resume passive wake (or muted, if user-disabled).
        // Do NOT pass through .idle: that flickers in the UI and reads as
        // "stopped" to the user even though wake is about to come back up.
        returnToPassiveWake(reason: reason)
    }

    // MARK: - Transcript → intent → action

    func handleTranscript(_ text: String) async {
        // Guard: empty transcript (e.g. STT no-speech noise) must not flow into
        // memory, summary, or notification code.
        let trimmedGuard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuard.isEmpty else {
            // No-op: empty or whitespace-only transcript — do not record, speak, or route.
            return
        }

        // User spoke — cancel any conversational timeout, mark session active,
        // and reset the 10-minute armed window from now.
        conversationalTimeoutTask?.cancel()
        conversationalTimeoutTask = nil
        conversationalSessionActive = true
        if conversationalArmed { armConversationalMode() }
        timingEngine.userStoppedSpeaking()  // final transcript = end of user turn
        ExecutionTracer.shared.addStep("transcript", detail: String(text.prefix(60)), runtimeID: "conversation")
        conversation.cancelTimeout()  // user spoke — cancel any silence timeout

        // Streaming interruption: if Jarvis was mid-sentence streaming, hand off the
        // user's text as an interruption so the pivot planner can build context.
        if StreamingConversationEngine.shared.isStreaming {
            StreamingConversationEngine.shared.handleInterruption(userText: text)
        }

        // === Step 0: pending context / follow-up resolution ===
        // If Jarvis asked the user a question, try to resolve the reply
        // BEFORE the normal routing pipeline so "yes", "Chrome", "the BBC one"
        // etc. dispatch to the right outcome without hitting the LLM routing.
        let normalizedQuick = TranscriptNormalizer.normalize(text)
        if let pending = activePendingContext, !pending.isExpired {
            let resolution = FollowUpResolver.resolve(
                normalized: normalizedQuick, pending: pending)
            state.lastFollowUpTranscript = text
            if resolution.shouldCallLLMWithHistory {
                // Resolution deferred to LLM — keep pending context alive so
                // tryLLMFallback can see it and inject conversation history.
                state.lastFollowUpResolution = "llm"
                state.log("conv", .info,
                    "follow_up_deferred_to_llm q=\"\(pending.assistantQuestion.prefix(40))\"")
                // Fall through — context still set, LLM will use history.
            } else if resolution.didHandle {
                clearPendingContext(resolution: resolution.reply != nil ? "yes/no→speak" : "intent")
                state.log("conv", .info,
                    "follow_up_resolved reply=\"\(resolution.reply?.prefix(40) ?? "-")\"")
                if let reply = resolution.reply { speak(reply) }
                if let intent = resolution.intent { await execute(intent) }
                return
            }
            // Not handled + not deferred → fall through with context still live
            // (gives the LLM a chance to resolve via history on the unknown path).
        }

        // Contextual pronoun resolution (no pending question, but session armed).
        if activePendingContext == nil && conversationalArmed {
            let pronoun = FollowUpResolver.resolveContextualPronoun(
                normalizedQuick,
                lastOverlayKind: state.sessionLastOverlayKind,
                lastPresentation: proactivity.latestPresentation
            )
            if let resolvedIntent = pronoun {
                state.log("conv", .info,
                    "contextual_pronoun_resolved text=\"\(normalizedQuick)\" intent=\(resolvedIntent)")
                await execute(resolvedIntent)
                return
            }
            // Cross-subsystem pronoun resolution.  When the legacy resolver
            // returned nil, consult `ActiveContextRegistry` — every subsystem
            // (camera, Shopify, Android, file search, Obsidian, …) registers
            // its user-visible output here, so "open the second one" / "call
            // him back" / "summarise that" can target anything Jarvis just
            // did, not just the proactivity tray + last overlay.
            if let action = resolveRegistryReference(normalizedQuick) {
                state.log("conv", .info,
                    "active_ctx_pronoun_resolved text=\"\(normalizedQuick)\" action=\(action.label)")
                if let reply = action.spokenReply { speak(reply) }
                if let intent = action.intent     { await execute(intent) }
                return
            }
        }

        // Start latency clock for route classification
        let routeClassificationStart = LatencyBudgetSystem.shared.startTimer()

        // === Step 1: normalize ===
        let prevActualForProcessing = state.listeningActualState.displayName
        if state.listeningActualState != .processing {
            state.listeningActualState = .processing
            state.pushLifecycleEvent(from: prevActualForProcessing, to: "Processing",
                                     reason: "transcript_received")
        }
        let rawTranscript = text
        let normalized = TranscriptNormalizer.normalize(text)
        let sessionShort = activeSession?.shortID ?? "-"
        let stateBefore = state.phase.rawValue
        let priorSpoken = state.lastSpoken
        let priorOverlayCount = overlayManager.overlays.count

        // === Step 2: parse ===
        let parsed = NaturalCommandParser.parse(
            rawText: rawTranscript,
            normalizedText: normalized
        )
        let parsedActionStr  = parsed.action.map { $0.rawValue } ?? "-"
        let parsedTargetStr  = parsed.target.map { $0.kind.rawValue } ?? "-"
        let parsedLabelStr   = parsed.target?.label ?? ""
        state.parsedAction     = parsedActionStr
        state.parsedTarget     = parsedTargetStr
        state.parsedConfidence = parsed.confidence
        state.lastNormalizedText = normalized
        state.log("pipeline", .info,
            "step=route_begin session=\(sessionShort) phase=\(stateBefore) raw=\"\(rawTranscript)\" norm=\"\(normalized)\" act=\(parsedActionStr) tgt=\(parsedTargetStr)\(parsedLabelStr.isEmpty ? "" : "(\(parsedLabelStr))") ord=\(parsed.ordinal.map(String.init) ?? "-") conf=\(String(format: "%.2f", parsed.confidence))")

        // Record in chat history and rolling dialogue memory
        appendChatMessage(ChatMessage(role: .user, text: text))
        rollingMemory.addUserTurn(rawTranscript, route: lastConvRouteResult?.route)

        // === Step 3a: phrase-store matching ===
        // Runs BEFORE IntentRouter so user-defined phrases take priority.
        // Clears stale diagnostics first, then attempts a match.
        state.phraseMatchedCommand  = nil
        state.phraseMatchedPhrase   = nil
        state.phraseMatchType       = nil
        state.phraseMatchConfidence = nil
        state.phraseNearMisses      = []

        // Voice-learning interception: "when I say X, [do / open / show] Y"
        if let learned = detectVoiceLearning(normalized: normalized) {
            handleVoiceLearning(learned, rawText: rawTranscript)
            return
        }

        // Local learning: correction detection ("no I meant X", "actually X", etc.)
        if learningEngine.detectAndRecordCorrection(transcript: rawTranscript) {
            speak(renderer.render(ResponseKey.learningAcknowledge))
            return
        }

        // === Step 2.5: Dual-lane ConversationRouter ===
        // Classifies transcripts into COMMAND vs chat/project/memory routes.
        // Only short-circuits to the conversational handler when the classifier
        // is confident (≥ 0.70) the utterance is NOT a command.
        // Commands always fall through to the existing phrase+intent pipeline.
        if prefs.current.conversationalModeEnabled {
            let convResult = conversationRouter.classifyFast(normalized, rawText: rawTranscript)
            lastConvRouteResult = convResult
            if prefs.current.conversationalDiagnosticsEnabled {
                state.log("conv_router", .info,
                    "route=\(convResult.route.rawValue) conf=\(String(format:"%.2f",convResult.confidence)) fast=\(convResult.fastPath) reason=\"\(convResult.rationale)\"")
            }
            if convResult.shouldShortCircuit {
                if convResult.route == .chatPlusToolPlusReasoning {
                    await handleToolPlusReasoning(
                        transcript: rawTranscript,
                        normalized: normalized,
                        toolHint: convResult.commandHint ?? "camera"
                    )
                } else {
                    await handleConversationalTurn(convResult, transcript: rawTranscript, normalized: normalized)
                }
                return
            }
        }

        // === Step 2.7: EntityFirstResolver ===
        // Runs before phrase matching so specific named entities ("EuroNews")
        // outrank generic category intents ("news"). Falls through when no
        // entity clears the confidence threshold.
        if let entityResult = await EntityFirstResolver.shared.resolve(
            transcript: normalized, rawText: rawTranscript
        ) {
            if entityResult.needsClarification,
               let competitor = entityResult.competingCandidates.first {
                let q = EntityIntentBinder.clarificationText(for: entityResult, against: competitor)
                speak(q)
                // Store pending context so the follow-up routes correctly
                activePendingContext = PendingConversationContext.clarification(
                    originalTranscript: rawTranscript, question: q)
                return
            }
            if let binding = EntityIntentBinder.bind(entityResult) {
                state.log("entity", .info,
                    "entity_resolved span=\"\(entityResult.originalSpan)\" → \(entityResult.displayName) [\(entityResult.entityType.rawValue)] conf=\(String(format:"%.2f",entityResult.confidence)) provider=\(entityResult.provider)")
                rollingMemory.addUserTurn(rawTranscript)
                speak(binding.spokenPrefix)
                await execute(binding.intent)
                return
            }
        }

        // === Camera-command trace ===
        // Emitted for every transcript that looks vision-related so we can
        // see exactly which stage it reaches (or fails at) in the debug log.
        let looksLikeVision: Bool = {
            let n = normalized
            return n.contains("see") || n.contains("look") || n.contains("describe")
                || n.contains("camera") || n.contains("vision") || n.contains("view")
        }()
        if looksLikeVision {
            let camDef = phraseStore.definitions.first { $0.id == "describe_camera" }
            let defPresent  = camDef != nil
            let defEnabled  = camDef?.enabled ?? false
            let phraseCount = camDef?.phrases.count ?? 0
            state.log("vision", .info,
                "camera_trace A raw=\"\(rawTranscript)\" B norm=\"\(normalized)\"")
            state.log("vision", .info,
                "camera_trace C store_has_describe_camera=\(defPresent) enabled=\(defEnabled) phrase_count=\(phraseCount)")
        }

        let phraseIntent: Intent? = {
            guard let match = phraseMatcher.match(
                normalizedInput: normalized,
                definitions: phraseStore.definitions)
            else {
                // Collect near-misses for diagnostics even when there's no match
                state.phraseNearMisses = phraseMatcher.nearMisses(
                    normalizedInput: normalized,
                    definitions: phraseStore.definitions)
                if looksLikeVision {
                    state.log("vision", .warn,
                        "camera_trace D phrase_store=NO_MATCH near_miss_count=\(state.phraseNearMisses.count)")
                }
                return nil
            }
            state.phraseMatchedCommand  = match.commandId
            state.phraseMatchedPhrase   = match.matchedPhrase
            state.phraseMatchType       = match.matchType
            state.phraseMatchConfidence = match.confidence
            let mappedIntent = IntentMapping.intent(for: match.commandId)
            if looksLikeVision {
                state.log("vision", .info,
                    "camera_trace D phrase_store=MATCH cmd=\(match.commandId) phrase=\"\(match.matchedPhrase)\" type=\(match.matchType.rawValue) conf=\(String(format:"%.2f",match.confidence)) E intent=\(mappedIntent.map{String(describing:$0)} ?? "nil")")
            }
            return mappedIntent
        }()

        // === Step 3: route ===
        latency.mark(.intentRoute)
        // Priority order:
        //   1. Phrase-store match (user-editable, data-driven)
        //   2. Parsed-command route (NLP-based structured parse)
        //   3. Substring router (legacy fallback)
        //   4. Emergency vision semantic fallback (see below)
        var intent: Intent
        var routedVia = "parsed"
        if let pi = phraseIntent {
            routedVia = "phrase_store"
            intent = pi
        } else if let r = router.route(parsed: parsed) {
            if looksLikeVision {
                state.log("vision", .info,
                    "camera_trace F parsed_route=\(String(describing:r))")
            }
            intent = r
        } else {
            routedVia = "substring"
            let substringIntent = router.route(normalized.isEmpty ? rawTranscript : normalized)
            if looksLikeVision {
                state.log("vision", .info,
                    "camera_trace F substring_route=\(String(describing:substringIntent))")
            }
            intent = substringIntent
        }
        latency.measure(from: .sttFinal, to: .intentRoute, recordAs: .intentRoute)
        state.lastIntent = intent
        history.append(transcript: text, intent: intent)
        context.recordIntent(intent, raw: text)
        let intentLabel = String(describing: intent).components(separatedBy: "(").first ?? String(describing: intent)
        conversations?.saveUserTurn(text, intent: intentLabel, sessionId: sessionId)
        if case .unknown = intent {
            state.log("pipeline", .warn,
                "step=unmatched_intent session=\(sessionShort) raw=\"\(rawTranscript)\" norm=\"\(normalized)\" — no route matched")
            // Record for the unmatched-command learning log.
            unmatched.record(UnmatchedCommandEntry(
                rawText: rawTranscript,
                normalizedText: normalized,
                action: parsed.action?.rawValue,
                target: parsed.target?.kind.rawValue,
                targetLabel: parsed.target?.label,
                activeOverlay: overlayManager.latestKind?.rawValue,
                phase: state.phase.rawValue
            ))
        } else {
            state.log("pipeline", .info,
                "step=routed session=\(sessionShort) via=\(routedVia) intent=\(intentLabel)")
        }

        // === Emergency semantic fallback: vision phrases must never reach .unknown ===
        // If all routing tiers failed AND the transcript strongly indicates a camera-
        // vision query, override to .whatCanYouSee rather than returning "I don't
        // have an action for that" to the user.
        if case .unknown = intent {
            let n = normalized
            let isVisionQuery =
                n.contains("what do you see") ||
                n.contains("what can you see") ||
                n.contains("what are you seeing") ||
                n.contains("what are you looking at") ||
                n.contains("look at this") ||
                n.contains("look around") ||
                (n.contains("describe") && (
                    n.contains("view") || n.contains("scene") ||
                    n.contains("camera") || n.contains("what you see") ||
                    n.contains("what you can see"))) ||
                (n.contains("what") && n.contains("see") && n.contains("you")) ||
                (n.contains("what") && n.contains("camera") && n.contains("see"))
            if isVisionQuery {
                state.log("vision", .warn,
                    "emergency_vision_semantic_fallback_used raw=\"\(rawTranscript)\" norm=\"\(normalized)\" — overriding .unknown → .whatCanYouSee")
                intent = .whatCanYouSee
            }
        }

        state.phase = .thinking
        state.pushTimeline(TimelineEvent(timestamp: Date(),
                                         symbol: "scope",
                                         title: text,
                                         detail: nil))

        // Record to activity timeline + entity graph
        activityTimeline.record(kind: .command, title: text,
                                detail: intentLabel, appName: state.activeApp)
        entityGraph.recordCommand(text, appName: state.activeApp)

        // Snapshot context before execution for reasoning trace
        let traceContext = context.snapshot.summaryString()
        let traceOverlays = overlayManager.overlays.map { $0.kind.rawValue }
        let traceAttention = state.attentionState
        let traceMode = state.operatingMode

        // === LLM fallback for unrecognised commands ===
        state.llmFallbackUsed = false
        var llmHandled = false
        if case .unknown = intent {
            // Fast path: deterministic conversational answers (no LLM, no network).
            if let fast = fastRouter.respond(
                normalized: normalized,
                prefs: prefs.current,
                state: state,
                llmMode: llmRouter.mode,
                capabilities: capabilities
            ) {
                latency.mark(.fastRoute)
                latency.measure(from: .sttFinal, to: .fastRoute, recordAs: .fastRoute)
                state.log("pipeline", .info,
                    "fast_response_hit source=\(fast.source.rawValue) conf=\(String(format: "%.2f", fast.confidence))")
                speak(fast.text)
                llmHandled = true
            } else {
                // Classify before calling the LLM so we can pick free-text
                // vs intent-JSON mode AND skip silently-falling-to-"no action".
                let kind = QuestionClassifier.classify(
                    rawTranscript,
                    hasPendingQuestion: activePendingContext != nil,
                    hasActiveContext: !activeContext.items.isEmpty)
                state.log("pipeline", .info,
                    "question_classifier kind=\(kind.rawValue) text=\"\(rawTranscript.prefix(60))\"")
                llmHandled = await routeUnknownByClassification(
                    kind: kind,
                    rawText: rawTranscript,
                    normalized: normalized)
            }
        }
        if !llmHandled {
            // A deterministic intent was routed — if there was a pending
            // context from a previous question, clear it now since the user
            // has moved on to a new command rather than answering the question.
            if activePendingContext != nil, case .unknown = intent {} else {
                clearPendingContext(resolution: "new_command")
            }

            // CHAT_PLUS_TOOL dual-track: when the ConversationRouter detected a
            // mixed utterance ("turn the lights on, but the calibration idea might
            // help"), execute the command silently (Track B) then generate a
            // conversational reply for the aside (Track A).
            let mixedResult = lastConvRouteResult?.route == .mixedChatAndCommand &&
                              (lastConvRouteResult?.confidence ?? 0) >= 0.70
                              ? lastConvRouteResult : nil
            if mixedResult != nil { suppressNextSpeak = true }

            // Publish intent resolution to SystemBus so EventStore + diagnostics can track the pipeline.
            LatencyBudgetSystem.shared.record(.routeClassification, since: routeClassificationStart)
            ExecutionTracer.shared.addStep("intent_resolved", detail: "\(intentLabel) via \(routedVia)", runtimeID: "conversation")
            SystemBus.shared.publish(IntentResolvedEvent(
                transcript: text,
                intentLabel: intentLabel,
                resolvedBy: routedVia
            ))
            await execute(intent)

            // Track A — conversational response for the aside after silent execution
            if let mixed = mixedResult {
                if prefs.current.conversationalDiagnosticsEnabled {
                    state.log("conv_router", .info,
                        "dual_track cmd=\(intentLabel) conf=\(String(format:"%.2f", mixed.confidence)) hint=\"\(mixed.commandHint ?? "—")\"")
                }
                await handleConversationalTurn(mixed, transcript: rawTranscript, normalized: normalized)
            }
        }

        // === Pipeline trace: AFTER execute ===
        let newOverlay = overlayManager.overlays.count > priorOverlayCount
            ? (overlayManager.overlays.last?.kind.rawValue ?? "?")
            : "none"
        let response = state.lastSpoken == priorSpoken ? "—" : state.lastSpoken
        let ttsRequested = response != "—"
        state.log("pipeline", .info,
            "step=executed session=\(sessionShort) intent=\(intentLabel) overlay=\(newOverlay) tts=\(ttsRequested) response=\"\(response.prefix(80))\"")

        // Finalise reasoning trace
        var trace = IntentTrace(
            transcript: text,
            intent: intent,
            activeApp: state.activeApp,
            attentionState: traceAttention,
            operatingMode: traceMode,
            openOverlays: traceOverlays,
            contextSummary: traceContext,
            actionSummary: intentLabel,
            responseSpeaken: state.lastSpoken
        )
        // Check for memory write
        if case .rememberThis(let mem) = intent { trace.memoryWrite = mem }
        if case .rememberLast = intent { trace.memoryWrite = state.sessionLastSpoken }
        reasoning.record(trace)
    }

    // MARK: - Remote transcript handling (DaemonAppBridge → Mac brain)

    /// Processes a transcript received from a remote Android/Windows device via the daemon.
    /// Unlike handleTranscript(), this:
    /// - Does NOT trigger TTS on the Mac unless prefs.speakRemoteRepliesOnMac == true
    /// - Does NOT start or extend a conversational session
    /// - Does NOT arm the conversational window
    /// - Returns the response text for routing back to the source device
    @MainActor
    func handleRemoteTranscript(_ text: String, context: RemoteDeviceContext) async -> RemoteBrainResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Empty transcript guard
        guard !trimmed.isEmpty else {
            state.remoteTranscriptRejectedCount += 1
            return .ignored("empty_transcript", routeId: context.routeId)
        }

        // 2. Dedup: reject if we already handled this routeId
        guard !handledRemoteRouteIds.contains(context.routeId) else {
            state.remoteTranscriptRejectedCount += 1
            return .ignored("duplicate_route_id", routeId: context.routeId)
        }

        // 3. TTL check: reject stale queued messages (> 90 seconds old)
        let age = Date().timeIntervalSince(context.receivedAt)
        guard age < 90 else {
            state.remoteTranscriptRejectedCount += 1
            return .ignored("stale_message_age_\(Int(age))s", routeId: context.routeId)
        }

        // 4. Record as handled (before await to prevent races)
        if handledRemoteRouteIds.count >= 200 {
            handledRemoteRouteIds.removeFirst()
        }
        handledRemoteRouteIds.append(context.routeId)

        state.remoteTranscriptReceivedCount += 1
        state.lastRemoteDevice = "\(context.platform)/\(context.deviceId)"
        state.lastRemoteTranscriptAt = Date()
        state.lastRemoteRouteId = context.routeId

        Log.app.info("[Remote] transcript from \(context.platform, privacy: .public)/\(context.deviceId, privacy: .public) len=\(trimmed.count, privacy: .public)")

        // 5. Install a response capture closure before routing.
        //    speak() will call this with the first generated text.
        var capturedResponse: String? = nil
        remoteResponseCapture = { text in
            if capturedResponse == nil { capturedResponse = text }
        }

        // 6. Suppress local TTS unless configured otherwise.
        let shouldSpeakLocally = prefs.current.speakRemoteRepliesOnMac
        if !shouldSpeakLocally { suppressNextSpeak = true }

        // 7. Run through the normal intent pipeline.
        //    The capture closure above will intercept the first speak() call.
        let normalized = TranscriptNormalizer.normalize(trimmed)

        // Try phrase store match → IntentMapping
        var handled = false
        if let match = phraseMatcher.match(normalizedInput: normalized,
                                           definitions: phraseStore.definitions),
           let intent = IntentMapping.intent(for: match.commandId) {
            await execute(intent)
            handled = true
        }

        // LLM fallback if no phrase match produced a response yet
        if !handled || capturedResponse == nil {
            let _ = await llmFallbackHandler?.handle(rawText: trimmed, normalized: normalized)
        }

        // Clear capture state
        remoteResponseCapture = nil
        suppressNextSpeak = false

        let rawResponseText = capturedResponse ?? ""

        // 8. Show remote activity in Mac UI if enabled
        if prefs.current.showRemoteActivityInMacUI {
            state.lastRemoteActivityText = "[\(context.platform)] \(String(trimmed.prefix(80)))"
        }

        // 9a. Empty / whitespace guard — never send a blank reply.
        //     The remote device's TTS engine must not receive empty text.
        let responseText = cappedForRemoteTts(rawResponseText)
        if responseText.isEmpty {
            // If the raw text was also blank the pipeline produced nothing useful.
            // Log the reason and return an error so the device recovers gracefully.
            let reason = rawResponseText.isEmpty ? "no_response_generated" : "response_blank_after_cap"
            state.remoteBrainErrorCount += 1
            return .error(reason, routeId: context.routeId)
        }

        // 9b. Final outcome — responseText is already capped to 3 sentences / 320 chars
        //     matching Android's ResponseFormatter contract.
        state.remoteTranscriptHandledCount += 1
        state.lastRemoteReplyAt = Date()
        state.remoteReplySentCount += 1

        return .reply(responseText, routeId: context.routeId,
                      speak: false,  // remote device handles its own TTS
                      display: true)
    }

    /// Routes a RemoteBrainResponse back through DaemonAppBridge to the originating device.
    @MainActor
    private func sendRemoteReply(_ response: RemoteBrainResponse, to context: RemoteDeviceContext) async {
        switch response.outcome {
        case .reply(let text, let speak, let display):
            DaemonAppBridge.shared.sendReply(
                text: text,
                speak: speak,
                display: display,
                routeId: response.routeId,
                targetPlatform: context.platform,
                targetDeviceId: context.deviceId
            )

        case .commandResult(let text, let intentLabel):
            DaemonAppBridge.shared.sendCommandResult(
                text: text,
                intentLabel: intentLabel,
                routeId: response.routeId,
                targetPlatform: context.platform,
                targetDeviceId: context.deviceId
            )

        case .error(let reason):
            DaemonAppBridge.shared.sendErrorReport(
                reason: reason,
                routeId: response.routeId,
                targetPlatform: context.platform,
                targetDeviceId: context.deviceId
            )
            state.remoteBrainErrorCount += 1

        case .ignored:
            break  // already counted in handleRemoteTranscript
        }
    }

    func execute(_ intent: Intent) async {
        latency.mark(.actionExecute)
        let intentLabel = String(describing: intent).components(separatedBy: "(").first
                          ?? String(describing: intent)
        defer {
            latency.measure(from: .intentRoute, to: .actionExecute, recordAs: .actionExecute)
            // Record intent for behaviour pattern learning.
            BehaviourPatternEngine.shared.recordIntent(
                intentLabel,
                inApp: worldState.activeApp
            )
            // Save an activity snapshot so "what was I doing earlier" works.
            snapshots?.save(
                phase: state.phase.rawValue,
                lastIntent: intentLabel,
                lastResponse: state.lastSpoken,
                sessionId: sessionId
            )
            if state.phase == .thinking {
                // Determine whether TTS was just queued (speak() sets lastSpeakCalledAt
                // synchronously, but state.isSpeaking flips asynchronously via the
                // isSpeakingStream — so we check both).
                let ttsJustQueued = lastSpeakCalledAt.timeIntervalSinceNow > -0.5
                if ttsJustQueued || state.isSpeaking {
                    // TTS is about to start (or already speaking).
                    // rewireSpeakingObserver will restart conversational STT after
                    // TTS finishes, giving the user the full silence-timeout window.
                    // Do NOT start STT now — that would eat into the user's response
                    // window while Jarvis is still talking.
                    state.log("conv", .debug, "execute_defer: TTS queued — deferring STT restart to rewireSpeakingObserver")
                } else if conversationalSessionActive
                   && prefs.current.conversationalFollowUpEnabled
                   && state.listeningEnabled {
                    // Non-TTS command (overlay open, clipboard, etc.) — restart STT
                    // immediately so the conversational window stays alive.
                    startConversationalListening()
                } else {
                    returnToPassiveWake(reason: .stateTransition)
                }
            }
        }
        switch intent {
        case .showCommandCentre:
            showCommandCentre()
            showToast("Command centre", icon: "rectangle.expand.vertical")
        case .hideCommandCentre:
            hideCommandCentre()
            showToast("Command centre hidden", icon: "rectangle.compress.vertical")
        case .toggleCommandCentre:  toggleCommandCentre()
        case .stopTalking:          stopSpeaking()
        case .status:               speak(statusSpoken())
        case .takePhoto:            _ = await captureCameraAndDescribe(announce: true)
        case .whatCanYouSee, .lookAtThis:
            showToast("Looking now…", icon: "eye")
            state.visionIsLoading = true
            let (sceneDesc, sceneResult) = await cameraAwareness.captureDescription(mode: .describe)
            applyVisionResult(sceneResult, summary: sceneDesc, mode: .describe)
            overlayManager.open(.camera)
            state.sessionLastOverlayKind = .camera
            speak(sceneDesc)
        case .describePerson:
            showToast("Looking…", icon: "person.fill.viewfinder")
            state.visionIsLoading = true
            let (personDesc, personResult) = await cameraAwareness.captureDescription(mode: .describePerson)
            applyVisionResult(personResult, summary: personDesc, mode: .describePerson)
            overlayManager.open(.camera)
            state.sessionLastOverlayKind = .camera
            speak(personDesc)
        case .whatIsOnDesk:
            showToast("Checking…", icon: "magnifyingglass")
            state.visionIsLoading = true
            let (deskDesc, deskResult) = await cameraAwareness.captureDescription(mode: .describeDesk)
            applyVisionResult(deskResult, summary: deskDesc, mode: .describeDesk)
            state.lastVisionSummary = deskDesc
            state.lastCameraSummary = deskDesc
            context.recordCamera(deskDesc)
            overlayManager.open(.camera)
            state.sessionLastOverlayKind = .camera
            speak(deskDesc)
        case .whatAmIHolding:
            showToast(renderer.render(ResponseKey.cameraHeldChecking), icon: "hand.raised.fill")
            state.visionIsLoading = true
            let (heldDesc, heldResult) = await cameraAwareness.captureDescription(mode: .detectHeldObject)
            applyVisionResult(heldResult, summary: heldDesc, mode: .detectHeldObject)
            overlayManager.open(.camera)
            state.sessionLastOverlayKind = .camera
            speak(heldDesc)
        case .readThis, .scanThis:
            let lines = await cameraAwareness.captureOCR()
            if lines.isEmpty {
                speak(renderer.render(ResponseKey.cameraOCREmpty))
            } else {
                state.lastSceneOCR = lines
                state.lastSceneTimestamp = Date()
                context.recordCamera("OCR: \(lines.prefix(3).joined(separator: ", "))")
                overlayManager.open(.camera)
                let joined = lines.prefix(5).joined(separator: ", ")
                speak(renderer.render(ResponseKey.cameraOCRFound, ["text": joined]))
            }
        case .isAnyoneThere:
            let presence = await cameraAwareness.capturePresence()
            state.lastPresenceSummary = presence.summary
            state.faceCount = presence.peopleCount
            state.lastSceneTimestamp = presence.timestamp
            context.recordPresence(presence)
            overlayManager.open(.camera)
            if presence.peopleCount > 0 {
                speak(renderer.render(ResponseKey.cameraPresenceFound,
                                      ["count": "\(presence.peopleCount)",
                                       "summary": presence.summary]))
            } else {
                speak(renderer.render(ResponseKey.cameraPresenceNone))
            }
        case .watchTheDesk:
            beginWatchingDesk()
            showToast("Camera watch started", icon: "video.fill")
        case .watchRoom:
            startCameraWatch()
            showToast("Camera watch started", icon: "video.fill")
        case .stopWatchingCamera:
            stopWatchingDesk()
            stopCameraWatch()
            showToast("Camera watch stopped", icon: "video.slash.fill")
            speak(renderer.render(ResponseKey.cameraWatchStopped))
        case .openApp(let name):
            showToast("Opening \(name)…", icon: "arrow.up.right.square")
            let appResult = await systemController.openApp(named: name)
            handleAppOpenResult(appResult, query: name)
            if case .opened(let opened) = appResult {
                entityGraph.recordAppOpen(opened)
                activityTimeline.record(kind: .command, title: "Open \(opened)", appName: state.activeApp)
            }
        case .openAppOnPhone(let name):
            guard requirePhoneOnline() else { return }
            showToast("Opening \(name) on phone…", icon: "iphone")
            let payload = AndroidCommandPayload(app: name)
            let response = await androidBridge?.sendToAndroid(
                command: AndroidCapability.appOpen,
                payload: payload,
                transcript: state.lastFinalTranscript,
                sessionId: sessionId)
            if response?.ok == true {
                speak(renderer.render(ResponseKey.openAppOnPhoneSuccess, ["app": name]))
            } else {
                speak(renderer.render(ResponseKey.openAppOnPhoneFailure, ["app": name]))
            }
        case .openURL(let url):
            showToast("Opening link", icon: "link")
            actions.openURL(url)
            speak(renderer.render(ResponseKey.openURLSuccess))
        case .useMicrophone(let name):
            selectMicrophone(named: name)
            speak(renderer.render(ResponseKey.micUpdated))
        case .useCamera(let name):
            selectCamera(named: name)
            speak(renderer.render(ResponseKey.cameraUpdated))
        // MARK: - Home Assistant — see HomeAssistantIntentHandler.swift

        case .homeStatus, .homeTurnOn, .homeTurnOff, .homeQueryEntity,
             .homeSetBrightness, .homeSetColor, .homeActivateScene,
             .homeRunAutomation, .homeOpenCover, .homeCloseCover,
             .homeLock, .homeUnlock, .homeShowCamera, .homeShowCameraOverlay,
             .homeCloseCamera, .homeShowAllCameras, .homeMuteAlerts,
             .homeUnmuteAlerts, .homeIgnoreCameraForHour, .homeShowHADiagnostics:
            await haIntentHandler.handle(intent)

        // MARK: - Calendar — see CalendarIntentHandler.swift

        case .showCalendar, .nextMeeting, .meetingsToday, .addReminder:
            await calendarIntentHandler.handle(intent)

        // MARK: - Todoist — see TodoistIntentHandler.swift

        case .showTasks, .whatAreMyTasks, .overdueTasks, .addTask, .completeTask:
            await todoistIntentHandler.handle(intent)

        // MARK: - Apple Notes — see NotesIntentHandler.swift

        case .openNotes, .showNotes, .createNote, .appendNote, .searchNotes:
            await notesIntentHandler.handle(intent)

        // MARK: - Email / Apple Mail — see EmailIntentHandler.swift

        case .checkEmail, .unreadEmail, .readLatestEmail, .searchEmail,
             .summariseEmail, .draftEmail, .replyEmail, .showEmail, .importantEmail:
            await emailIntentHandler.handle(intent)

        case .continueFromAndroid:
            showCommandCentre()
            if !state.lastAndroidContext.isEmpty {
                speak(renderer.render(ResponseKey.androidContinue,
                                      ["context": state.lastAndroidContext]))
            } else {
                speak(renderer.render(ResponseKey.androidNothing))
            }
        case .showContext:
            showCommandCentre()
            speak(renderer.render(ResponseKey.showContext))
        case .repeatLast:
            let last = state.sessionLastSpoken
            if last.isEmpty {
                speak(renderer.render(ResponseKey.repeatEmpty))
            } else {
                speak(last)
            }
        case .focusMode:
            // Close all overlays to return to the clean orb view.
            overlayManager.closeAll()
            showToast("Orb mode")
            speak(renderer.render(ResponseKey.orbMode))
        case .dashboardMode:
            // Close overlays — workspace panels open as overlays, not a separate screen.
            overlayManager.closeAll()
            showToast("Workspace mode")
            speak(renderer.render(ResponseKey.dashboardMode))
        case .showTestOverlay:
            overlayManager.open(.test)
            state.sessionLastOverlayKind = .test
            speak(renderer.render(ResponseKey.overlayTestOpened))
        case .closeOverlay:
            // Prefer the visually-focused (top) overlay so "close that"
            // matches what the user is looking at, not the last one we
            // happened to open programmatically.
            // Pinned overlays are skipped — voice commands cannot close them.
            if let kind = overlayManager.closeTop() {
                if state.sessionLastOverlayKind == kind {
                    state.sessionLastOverlayKind = nil
                }
                state.lastOverlayEvent = "closed:\(kind.rawValue)"
                showToast("\(kind.title) closed", icon: "xmark.circle.fill")
                speak(renderer.render(ResponseKey.overlayClosed, ["name": kind.title.lowercased()]))
            } else if overlayManager.overlays.isEmpty {
                showToast("Nothing to close", icon: "xmark.circle")
                speak(renderer.render(ResponseKey.overlayNoneOpen))
            } else {
                // All visible overlays are pinned
                showToast("Overlay is pinned", icon: "pin.fill")
                speak("That overlay is pinned — say \"unpin\" to close it.")
            }
        case .pinOverlay:
            overlayManager.pinTopOverlay()
            showToast("Overlay pinned", icon: "pin.fill")
            speak(renderer.render(ResponseKey.overlayPinned, [:]))
        case .unpinOverlay:
            overlayManager.unpinTopOverlay()
            showToast("Overlay unpinned", icon: "pin")
            speak(renderer.render(ResponseKey.overlayUnpinned, [:]))
        case .overlayResetLayout:
            overlayManager.resetLayout()
            showToast("Layout reset", icon: "rectangle.3.group")
            speak(renderer.render(ResponseKey.overlayLayoutReset, [:]))
        case .overlayFocusTop:
            if let kind = overlayManager.latestKind {
                overlayManager.focus(kind)
                showToast("Focused \(kind.title)", icon: kind.systemImage)
                speak(renderer.render(ResponseKey.overlayBroughtToFront, [:]))
            }
        case .maximizeOverlay:
            overlayManager.enlargeTop()
            showToast("Enlarged", icon: "arrow.up.left.and.arrow.down.right")
        case .minimizeOverlay:
            overlayManager.minimizeTop()
            showToast("Minimised", icon: "minus.circle.fill")
        case .showChat:
            await loadChatHistory()
            overlayManager.open(.chat)
            state.sessionLastOverlayKind = .chat
        case .showDebugHUD:
            state.debugHUDVisible = true
            speak(renderer.render(ResponseKey.debugHUDOn))
        case .hideDebugHUD:
            state.debugHUDVisible = false
            speak(renderer.render(ResponseKey.debugHUDOff))
        case .showResponsePlaybook:
            showToast("Opening response settings", icon: "text.bubble")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        case .showPersonalitySettings:
            showToast("Opening personality settings", icon: "person.fill")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        case .reloadPersonality:
            personality.reload()
            syncPersonality()
            showToast("Personality reloaded", icon: "arrow.clockwise")

        // Operating modes
        case .modeNormal:
            state.operatingMode = .normal
            state.ambientModeEnabled = false
            syncOperatingMode()
            speak(renderer.render(ResponseKey.modeNormal))
        case .modeConcise:
            state.operatingMode = .concise
            syncOperatingMode()
            showToast("Concise mode", icon: OperatingMode.concise.symbol)
            speak(renderer.render(ResponseKey.modeConcise))
        case .modeSilent:
            state.operatingMode = .silent
            syncOperatingMode()
            showToast("Silent mode — text only", icon: OperatingMode.silent.symbol)
        case .modeAmbient:
            state.operatingMode = .ambient
            state.ambientModeEnabled = true
            prefs.update { $0.ambientModeEnabled = true }
            syncOperatingMode()
            showToast("Ambient mode", icon: OperatingMode.ambient.symbol)
            speak(renderer.render(ResponseKey.modeAmbient))

        // Timeline
        case .showTimeline:
            overlayManager.open(.timeline)
            state.sessionLastOverlayKind = .timeline
            let todayCount = activityTimeline.today().count
            speak(renderer.render(ResponseKey.timelineOpened, ["count": "\(todayCount)"]))
        case .whatDidIDoToday:
            overlayManager.open(.timeline)
            state.sessionLastOverlayKind = .timeline
            let todayEvents = activityTimeline.today()
            speak(renderer.render(ResponseKey.whatDidIDoToday,
                                  ["count": "\(todayEvents.count)"]))

        // Reasoning
        case .showReasoning:
            overlayManager.open(.reasoning)
            state.sessionLastOverlayKind = .reasoning
            speak(renderer.render(ResponseKey.reasoningOpened))
        case .whyDidYouDoThat:
            let explanation = reasoning.explain(last: 1)
            speak(explanation)

        // Attention + entity info
        case .showAttentionState:
            speak(renderer.render(ResponseKey.attentionState,
                                  ["attention": state.attentionState.displayName,
                                   "mode": state.operatingMode.displayName]))
        case .showEntityGraph:
            let top = entityGraph.topNodes(limit: 5).map { $0.label }
            if top.isEmpty {
                speak(renderer.render(ResponseKey.homeEntitiesNone))
            } else {
                speak(renderer.render(ResponseKey.homeEntitiesList,
                                      ["entities": top.joined(separator: ", ")]))
            }

        // News
        case .showNews:
            // ALWAYS switch to headlines mode + stop any live video.
            // Previously this block early-returned with `focus` when the
            // overlay was already open, leaving `newsOverlayMode = .watch`
            // from a prior "watch news" — so the user saw the player and
            // empty channel strip but no headline feed.  The mode reset
            // and `exitMediaPlayback` now run unconditionally so the user
            // can flip from watch → headlines just by saying "show news".
            state.newsLivePlayerVisible = false
            state.newsOverlayMode = .headlines
            exitMediaPlayback()
            if overlayManager.isOpen(.news) {
                overlayManager.focus(.news)
                state.log("news", .info,
                    "news_overlay_focused mode=headlines (was watch)")
                speak(renderer.render(ResponseKey.newsAlreadyOpen))
            } else {
                openOverlay(.news)
                state.activeNewsChannelName = newsChannelStore.activeChannel?.name ?? ""
                state.log("news", .info,
                    "news_overlay_opened mode=headlines channel=\(state.activeNewsChannelName)")
                speak(renderer.render(ResponseKey.newsOpened))
            }

        case .watchNews:
            // "watch news" → watch mode: live video, no headline feed,
            // active STT paused, wake-word only.
            state.newsLivePlayerVisible = true
            state.newsOverlayMode = .watch
            if !overlayManager.isOpen(.news) {
                openOverlay(.news)
            } else {
                overlayManager.focus(.news)
            }
            if let ch = newsChannelStore.defaultChannel {
                newsChannelStore.setActive(id: ch.id)
                onNewsChannelChanged(ch)
                enterMediaPlayback(channel: ch.name)
                speak(renderer.render(ResponseKey.newsWatching, ["channel": ch.name]))
            } else {
                speak(renderer.render(ResponseKey.newsChannelNone))
            }

        case .watchNewsChannel(let name):
            // "watch Bloomberg" always means: watch mode + this channel.
            state.newsLivePlayerVisible = true
            state.newsOverlayMode = .watch
            if !overlayManager.isOpen(.news) {
                openOverlay(.news)
            } else {
                overlayManager.focus(.news)
            }
            if let ch = newsChannelStore.setActive(byNameContaining: name) {
                onNewsChannelChanged(ch)
                enterMediaPlayback(channel: ch.name)
                speak(renderer.render(ResponseKey.newsChannelSwitched, ["channel": ch.name]))
            } else {
                speak(renderer.render(ResponseKey.newsChannelNotFound, ["channel": name.capitalized]))
            }

        case .nextNewsChannel:
            if let ch = newsChannelStore.cycleNext() {
                onNewsChannelChanged(ch)
                speak(renderer.render(ResponseKey.newsChannelSwitched, ["channel": ch.name]))
                state.newsLivePlayerVisible = true
                state.newsOverlayMode = .watch
                enterMediaPlayback(channel: ch.name)
                if !overlayManager.isOpen(.news) { openOverlay(.news) }
            } else {
                speak(renderer.render(ResponseKey.newsChannelsNone))
            }

        case .prevNewsChannel:
            if let ch = newsChannelStore.cyclePrev() {
                onNewsChannelChanged(ch)
                speak(renderer.render(ResponseKey.newsChannelSwitched, ["channel": ch.name]))
                state.newsLivePlayerVisible = true
                state.newsOverlayMode = .watch
                enterMediaPlayback(channel: ch.name)
                if !overlayManager.isOpen(.news) { openOverlay(.news) }
            } else {
                speak(renderer.render(ResponseKey.newsChannelsNone))
            }

        case .summariseNews:
            let articles = newsStore.recentArticlesSync(limit: 6)
            if articles.isEmpty {
                speak(renderer.render(ResponseKey.newsNoArticles))
            } else {
                let digest = await summariseNewsWithLLM(articles)
                speak(digest)
            }

        case .openStoryAt(let index):
            let articles = newsStore.recentArticlesSync(limit: 40)
            guard articles.indices.contains(index - 1) else {
                let cnt = articles.count
                speak(renderer.render(ResponseKey.newsArticleLimited,
                                      ["count": "\(cnt)",
                                       "count_label": cnt == 1 ? "story" : "stories"]))
                state.log("news", .warn,
                    "article_open_requested index=\(index) out_of_range count=\(cnt)")
                return
            }
            let article = articles[index - 1]
            state.log("news", .info,
                "article_open_requested index=\(index) title=\"\(article.title.prefix(60))\"")
            openArticle(article)
            speak(renderer.render(ResponseKey.newsArticleOpening, ["index": "\(index)"]))

        case .summariseStoryAt(let index):
            let articles = newsStore.recentArticlesSync(limit: 40)
            guard articles.indices.contains(index - 1) else {
                let cnt2 = articles.count
                speak(renderer.render(ResponseKey.newsArticleLimited,
                                      ["count": "\(cnt2)",
                                       "count_label": cnt2 == 1 ? "story" : "stories"]))
                return
            }
            let article = articles[index - 1]
            state.log("news", .info,
                "headline_summarise_requested index=\(index)")
            if !article.summary.isEmpty {
                speak(article.summary)
            } else {
                speak(renderer.render(ResponseKey.summariseUnavailable))
            }

        case .openInBrowser:
            if let url = state.currentArticleURL {
                actions.openURL(url)
                state.log("news", .info, "article_opened_in_browser url=\(url.absoluteString)")
                speak(renderer.render(ResponseKey.newsArticleBrowser))
            } else {
                speak(renderer.render(ResponseKey.newsArticleNoFocus))
            }

        case .hideArticle:
            if overlayManager.close(.article) {
                state.currentArticleURL = nil
                state.currentArticleTitle = ""
                state.currentArticleSource = ""
                showToast("Article closed", icon: "doc.text")
                speak(renderer.render(ResponseKey.newsArticleClosed))
            } else {
                speak(renderer.render(ResponseKey.newsArticleNone))
            }

        case .showNewsLabel(let labelStr):
            openOverlay(.news)
            let label = NewsLabel(rawValue: labelStr)
            Task {
                let articles = label != nil
                    ? await newsStore.articlesForLabel(label!)
                    : newsStore.recentArticlesSync(limit: 40)
                if articles.isEmpty {
                    speak(renderer.render(ResponseKey.newsNoArticles))
                } else {
                    let digest = NewsSummariser.digestSummary(articles: articles, label: label)
                    speak(digest)
                }
            }

        case .searchNews(let query):
            Task {
                let results = await newsStore.searchArticles(query: query)
                if results.isEmpty {
                    speak(renderer.render(ResponseKey.newsSearchEmpty, ["query": query]))
                } else {
                    openOverlay(.news)
                    let titles = results.prefix(3).map { "• \($0.title)" }.joined(separator: " ")
                    speak(renderer.render(ResponseKey.newsSearchFound,
                                          ["count": "\(results.count)", "summary": titles]))
                }
            }

        case .refreshNews:
            Task {
                let count = await newsScheduler.refreshAll()
                speak(renderer.render(ResponseKey.newsRefreshed, ["count": "\(count)"]))
            }

        case .watchFeed(let name):
            let lower = name.lowercased()
            if let feed = newsStore.feeds.first(where: { $0.name.lowercased().contains(lower) }) {
                newsScheduler.addWatch(feedID: feed.id)
                speak(renderer.render(ResponseKey.newsWatchStarted, ["feed": feed.name]))
            } else {
                speak(renderer.render(ResponseKey.newsFeedNotFound, ["name": name]))
            }

        case .stopWatchingNews:
            newsScheduler.removeAllWatches()
            speak(renderer.render(ResponseKey.newsWatchStopped))

        case .saveNewsArticle:
            let articles = newsStore.recentArticlesSync(limit: 1)
            if let article = articles.first {
                newsStore.toggleSaved(article: article)
                speak(renderer.render(ResponseKey.newsSaved))
                memories?.remember("Saved article: \(article.title) — \(article.url)")
            } else {
                speak(renderer.render(ResponseKey.newsNoRecentArticle))
            }

        case .showSavedNews:
            openOverlay(.news)
            speak(renderer.render(ResponseKey.newsSavedOpened))

        // Memory — explicit storage
        case .rememberThis(let text):
            memories?.remember(text)
            showToast("Saved to memory")
            speak(renderer.render(ResponseKey.memorySaved))
            activityTimeline.record(kind: .memorySaved, title: "Remembered",
                                    detail: String(text.prefix(60)), appName: state.activeApp)
            entityGraph.recordMemory(UUID().uuidString, appName: state.activeApp)

        case .rememberLast:
            let toSave = state.sessionLastSpoken
            if toSave.isEmpty {
                speak(renderer.render(ResponseKey.memoryNothingToSave))
            } else {
                memories?.remember(toSave)
                showToast("Saved to memory")
                speak(renderer.render(ResponseKey.memorySavedLast))
            }

        case .searchMemory(let query):
            if let svc = search {
                lastSearchQuery = query
                state.lastSearchQuery = query
                let results = await svc.search(query: query, limit: 15)
                state.memorySearchResults = results
                state.memoryRows = []
                state.recentConversations = []
                overlayManager.open(.memory)
                state.sessionLastOverlayKind = .memory
                if results.isEmpty {
                    speak(renderer.render(ResponseKey.memorySearchEmpty, ["query": query]))
                } else {
                    let snippet = results.first?.snippet ?? ""
                    let countStr = "\(results.count)"
                    let label = results.count == 1 ? "result" : "results"
                    speak(renderer.render(ResponseKey.memorySearchFound,
                                          ["count": countStr, "count_label": label, "snippet": snippet]))
                }
            } else {
                speak(renderer.render(ResponseKey.memoryUnavailable))
            }

        case .searchAgain:
            if lastSearchQuery.isEmpty {
                speak(renderer.render(ResponseKey.memorySearchNoPrev))
            } else {
                await execute(.searchMemory(query: lastSearchQuery))
            }

        case .whatDoYouRemember:
            // Speak the top 5 memories without opening the overlay.
            // The resolver formats a TTS-friendly bullet list.
            Log.llm.info("[identity] whatDoYouRemember — speaking, no overlay")
            let memRows = (await memories?.all(limit: 20)) ?? []
            let resolver = PersonalFactsResolver()
            let answer = resolver.buildMemoryAnswer(memories: memRows, limit: 5)
            speak(answer)
            // Preload state so overlay is ready if user asks for it next
            state.memoryRows = memRows
            state.memorySearchResults = []
            state.recentConversations = []

        // Identity — direct spoken answers, no overlay
        case .askMyName:
            Log.llm.info("[identity] askMyName")
            let name = prefs.current.userName ?? ""
            let resolver = PersonalFactsResolver()
            speak(resolver.answerMyName(userName: name))

        case .askAssistantName:
            Log.llm.info("[identity] askAssistantName")
            let resolver = PersonalFactsResolver()
            speak(resolver.answerAssistantName(assistantName: prefs.current.assistantName))

        case .askPersonalFacts:
            Log.llm.info("[identity] askPersonalFacts")
            let memRows = (await memories?.all(limit: 20)) ?? []
            let resolver = PersonalFactsResolver()
            let answer = resolver.buildPersonalFactsAnswer(
                userName: prefs.current.userName ?? "",
                memories: memRows,
                limit: 5
            )
            speak(answer)

        // Conversational Jarvis (Sprint K)
        case .saveToProjectMemory:
            let result = handleMemoryUpdateTurn(transcript: state.lastNormalizedText, normalized: state.lastNormalizedText)
            speak(result)

        case .logProgressNote(let text):
            let content = text.isEmpty ? (state.lastSpoken ?? "") : text
            memories?.remember(content, tags: "project,progress,manual")
            if prefs.current.conversationalDailyNotesEnabled {
                Task {
                    await obsidianExporter.export(content: content, section: .projectProgress, vaultPath: prefs.current.obsidianVaultPath)
                }
            }
            speak(renderer.render(ResponseKey.progressSaved))

        case .queryProjectMemory(let query):
            let q = query.isEmpty ? "project status" : query
            let ctx = await projectKnowledge.retrieve(for: q, route: .knowledgeQuery)
            if ctx.isEmpty {
                speak(renderer.render(ResponseKey.noProjectMemory))
            } else {
                let answer = await answerComposer.compose(
                    transcript: q,
                    route: .knowledgeQuery,
                    knowledgeContext: ctx,
                    recentChatHistory: nil,
                    userName: prefs.current.userName
                )
                speak(answer ?? renderer.render(ResponseKey.noProjectMemory))
            }

        case .showTodayJarvisLog:
            guard let vaultPath = prefs.current.obsidianVaultPath else {
                speak(renderer.render(ResponseKey.todayLogNotFound))
                return
            }
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            let filePath = (vaultPath as NSString)
                .appendingPathComponent("Jarvis")
                .appending("/\(fmt.string(from: Date())).md")
            if FileManager.default.fileExists(atPath: filePath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                speak("Opening today's Jarvis log.")
            } else {
                speak(renderer.render(ResponseKey.todayLogNotFound))
            }

        case .pauseMemoryLogging:
            memoryLoggingPaused = true
            speak(renderer.render(ResponseKey.memoryLoggingPaused))

        case .resumeMemoryLogging:
            memoryLoggingPaused = false
            speak(renderer.render(ResponseKey.memoryLoggingResumed))

        case .doNotSaveThis:
            speak(renderer.render(ResponseKey.doNotSaveThis))
            // The next turn will still be processed; this just signals ephemeral intent

        case .showProjectStatus:
            let ctx = await projectKnowledge.retrieve(for: "project status overview", route: .projectReflection)
            speak(renderer.render(ResponseKey.showingProjectStatus))
            let answer = await answerComposer.compose(
                transcript: "Give me an overview of the current project status",
                route: .projectReflection,
                knowledgeContext: ctx,
                recentChatHistory: nil,
                userName: prefs.current.userName
            )
            if let a = answer, a != state.lastSpoken { speak(a) }

        case .whatHaveIBuilt:
            let ctx = await projectKnowledge.retrieve(for: "what have I built completed implemented", route: .knowledgeQuery)
            let progress = ConversationMemoryStore.shared.recentByType(.projectProgress, limit: 5)
                .map { "- \($0.summary)" }.joined(separator: "\n")
            if progress.isEmpty && ctx.isEmpty {
                speak(renderer.render(ResponseKey.noProjectMemory))
            } else {
                speak("Based on the project log: " + (ctx.projectFacts.first ?? progress))
            }

        case .whatIsMissing:
            let ctx = await projectKnowledge.retrieve(for: "what is missing left to build TODO roadmap", route: .projectReflection)
            let answer = await answerComposer.compose(
                transcript: "What is still missing or left to build in this project?",
                route: .projectReflection,
                knowledgeContext: ctx,
                recentChatHistory: nil,
                userName: prefs.current.userName
            )
            speak(answer ?? renderer.render(ResponseKey.noProjectMemory))

        case .showRoutingDiagnostics:
            if let last = lastConvRouteResult {
                speak("Last route: \(last.route.rawValue), confidence \(Int(last.confidence * 100))%, \(last.fastPath ? "fast path" : "LLM"). Reason: \(last.rationale).")
            } else {
                speak("No routing diagnostics yet.")
            }

        // MARK: Visual Intelligence / POI Surveillance (Sprint L)

        case .showSurveillanceMode:
            openOverlay(.surveillance)
            speak(renderer.render(ResponseKey.surveillanceModeOpened))

        case .hideSurveillanceMode:
            overlayManager.close(.surveillance)
            speak("Surveillance display closed.")

        case .startSurveillance:
            VisionModule.shared.start()
            speak(renderer.render(ResponseKey.surveillanceActive, [
                "count": "\(VisionModule.shared.activeFeedCount)",
                "count_suffix": VisionModule.shared.activeFeedCount == 1 ? "" : "s"
            ]))

        case .stopSurveillance:
            VisionModule.shared.stop()
            speak(renderer.render(ResponseKey.surveillanceStopped))

        case .describeVisualScene:
            let description = VisionModule.shared.describeCurrentScene()
            speak(renderer.render(ResponseKey.sceneDescription, ["description": description]))

        case .whoIsAtLocation(let location):
            let loc = location.isEmpty ? "door" : location
            let answer = VisionModule.shared.describeActivity(at: loc)
            speak(answer)

        case .anyPeopleDetected:
            let targets = VisionModule.shared.allActiveTargets.filter { !$0.isGhost && $0.cls == .person }
            if targets.isEmpty {
                speak(renderer.render(ResponseKey.noActivityDetected))
            } else {
                speak("Yes, I can see \(targets.count) person\(targets.count == 1 ? "" : "s") across the camera feeds.")
            }

        case .focusCamera(let name):
            openOverlay(.surveillance)
            speak(renderer.render(ResponseKey.cameraFocused, ["camera": name.isEmpty ? "main camera" : name]))

        case .addRTSPCamera(let name, let url):
            VisionModule.shared.addRTSPFeed(name: name, url: url, location: name)
            speak("Added camera \(name). I'll start monitoring that feed.")

        case .lastMotionEvent:
            let events = VisionModule.shared.sceneMemory.events
            if let last = events.first {
                let timeStr = last.timestamp.formatted(.dateTime.hour().minute())
                speak(renderer.render(ResponseKey.motionEventReport, [
                    "description": last.description,
                    "time": timeStr,
                    "camera": last.cameraName
                ]))
            } else {
                speak("No motion events recorded yet.")
            }

        case .showThreatStatus:
            let threat = VisionModule.shared.threatClassifier.sceneThreatLevel
            let reason = VisionModule.shared.threatClassifier.threatReason
            let reasonText = reason.isEmpty ? "All feeds normal." : reason
            speak(renderer.render(ResponseKey.threatStatusReport, [
                "level": threat.systemLabel,
                "reason": reasonText
            ]))

        case .activateThreatTracking:
            VisionModule.shared.start()
            speak(renderer.render(ResponseKey.trackingActivated))

        // MARK: Spatial Interaction Phase 1 (Sprint M)

        case .saveWorkspace(let name):
            let finalName = name.isEmpty ? "Workspace \(AirDock.shared.workspaces.count + 1)" : name
            _ = AirDock.shared.save(name: finalName, widgetStates: [], overlayKinds: [])
            speak(renderer.render(ResponseKey.workspaceSaved, ["name": finalName]))

        case .restoreWorkspace(let name):
            if let ws = AirDock.shared.fuzzyMatch(query: name.isEmpty ? "" : name) {
                AirDock.shared.activate(id: ws.id)
                speak(renderer.render(ResponseKey.workspaceRestored, ["name": ws.name]))
            } else {
                speak(renderer.render(ResponseKey.workspaceNotFound, ["name": name.isEmpty ? "that" : name]))
            }

        case .listWorkspaces:
            let workspaces = AirDock.shared.workspaces
            if workspaces.isEmpty {
                speak(renderer.render(ResponseKey.noWorkspacesSaved))
            } else {
                let list = workspaces.map { "\($0.thumbnail ?? "🗂️") \($0.name)" }.joined(separator: ", ")
                speak(renderer.render(ResponseKey.workspaceList, ["list": list]))
            }

        case .moveWidgetLeft:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                SpatialWidgetManager.shared.moveWidget(id: id, direction: .left, amount: 60)
                speak(renderer.render(ResponseKey.widgetMoved, ["direction": "left"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .moveWidgetRight:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                SpatialWidgetManager.shared.moveWidget(id: id, direction: .right, amount: 60)
                speak(renderer.render(ResponseKey.widgetMoved, ["direction": "right"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .moveWidgetUp:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                SpatialWidgetManager.shared.moveWidget(id: id, direction: .up, amount: 60)
                speak(renderer.render(ResponseKey.widgetMoved, ["direction": "up"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .moveWidgetDown:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                SpatialWidgetManager.shared.moveWidget(id: id, direction: .down, amount: 60)
                speak(renderer.render(ResponseKey.widgetMoved, ["direction": "down"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .resizeWidgetLarge:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                let w = SpatialWidgetManager.shared.widget(for: id)
                let newSize = CGSize(width: (w?.frame.width ?? 400) * 1.3, height: (w?.frame.height ?? 300) * 1.3)
                SpatialWidgetManager.shared.resizeWidget(id: id, to: newSize)
                speak(renderer.render(ResponseKey.widgetResized, ["action": "enlarged"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .resizeWidgetSmall:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                let w = SpatialWidgetManager.shared.widget(for: id)
                let newSize = CGSize(width: (w?.frame.width ?? 400) * 0.75, height: (w?.frame.height ?? 300) * 0.75)
                SpatialWidgetManager.shared.resizeWidget(id: id, to: newSize)
                speak(renderer.render(ResponseKey.widgetResized, ["action": "shrunk"]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .minimizeWidget:
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                SpatialWidgetManager.shared.minimizeWidget(id: id)
                speak(renderer.render(ResponseKey.widgetMinimized))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .dockWidget(let edge):
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                let dockEdge = DockEdge(rawValue: edge) ?? .left
                SpatialWidgetManager.shared.dockWidget(id: id, to: dockEdge, screenSize: CGSize(width: 1440, height: 900))
                speak(renderer.render(ResponseKey.widgetDocked, ["edge": edge]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .snapWidget(let zone):
            let wid = SpatialWidgetManager.shared.activeWidgetID
            if let id = wid {
                let snapZone = SnapZone(rawValue: zone) ?? .center
                SpatialWidgetManager.shared.snapToZone(snapZone, widgetID: id, screenSize: CGSize(width: 1440, height: 900))
                speak(renderer.render(ResponseKey.widgetSnapped, ["zone": zone]))
            } else { speak(renderer.render(ResponseKey.noWidgetHovered)) }

        case .showSpatialDebug:
            openOverlay(.spatialHUD)
            speak("Opening spatial diagnostics.")

        case .snapWindowLeft(let appName):
            let found = await SpatialWindowManager.shared.findAndSnap(matching: appName.isEmpty ? "" : appName, to: .leftHalf)
            if found {
                let label = appName.isEmpty ? "window" : appName
                speak(renderer.render(ResponseKey.windowSnapped, ["app": label, "side": "left"]))
            } else {
                speak(renderer.render(ResponseKey.windowNotFound, ["app": appName.isEmpty ? "that app" : appName]))
            }

        case .snapWindowRight(let appName):
            let found = await SpatialWindowManager.shared.findAndSnap(matching: appName.isEmpty ? "" : appName, to: .rightHalf)
            if found {
                let label = appName.isEmpty ? "window" : appName
                speak(renderer.render(ResponseKey.windowSnapped, ["app": label, "side": "right"]))
            } else {
                speak(renderer.render(ResponseKey.windowNotFound, ["app": appName.isEmpty ? "that app" : appName]))
            }

        case .tileWindows:
            await SpatialWindowManager.shared.refreshWindows()
            let targets: [WindowSnapTarget] = [.leftHalf, .rightHalf]
            await SpatialWindowManager.shared.tileWindows(targets: targets)
            speak(renderer.render(ResponseKey.windowsTiled))

        case .focusWindow(let appName):
            let found = await SpatialWindowManager.shared.findAndFocus(matching: appName)
            if found {
                speak(renderer.render(ResponseKey.windowFocused, ["app": appName]))
            } else {
                speak(renderer.render(ResponseKey.windowNotFound, ["app": appName.isEmpty ? "that app" : appName]))
            }

        case .showRecentMemories:
            state.memoryRows = (await memories?.all(limit: 50)) ?? []
            state.memorySearchResults = []
            state.recentConversations = []
            overlayManager.open(.memory)
            state.sessionLastOverlayKind = .memory
            let count = state.memoryRows.count
            if count == 0 {
                speak(renderer.render(ResponseKey.memoryRecentEmpty))
            } else {
                let label = count == 1 ? "memory" : "memories"
                speak(renderer.render(ResponseKey.memoryRecentFound,
                                      ["count": "\(count)", "count_label": label]))
            }

        case .showMemoryOverlay:
            state.memoryRows = (await memories?.all(limit: 30)) ?? []
            state.recentConversations = (await search?.recentConversations(limit: 20)) ?? []
            state.memorySearchResults = []
            overlayManager.open(.memory)
            state.sessionLastOverlayKind = .memory
            speak(renderer.render(ResponseKey.memoryOverlayOpened))

        // Activity / context recall
        case .whatWasIDoingEarlier:
            // Enrich with graph continuity chain (Sprint W)
            let leftOff = FocusContextResponder.leftOffSummary(
                graphIndex: contextGraph, threadEngine: taskThreadEngine)
            if let svc = search {
                let summary = await svc.recentActivitySummary(limit: 5)
                state.recentSnapshots = (await snapshots?.recent(limit: 10)) ?? []
                state.recentConversations = (await svc.recentConversations(limit: 10)) ?? []
                overlayManager.open(.memory)
                state.sessionLastOverlayKind = .memory
                let base = leftOff.isEmpty ? summary : leftOff + " " + summary
                speak(base)
            } else {
                if !leftOff.isEmpty {
                    speak(leftOff)
                } else {
                    let threadSummary = taskThreadEngine.lastWorkSummary
                    speak(threadSummary.isEmpty ? renderer.render(ResponseKey.activityUnavailable) : threadSummary)
                }
            }

        case .showRecentActivity:
            state.recentSnapshots = (await snapshots?.recent(limit: 10)) ?? []
            state.recentConversations = (await search?.recentConversations(limit: 20)) ?? []
            state.memoryRows = []
            state.memorySearchResults = []
            overlayManager.open(.memory)
            state.sessionLastOverlayKind = .memory
            speak(renderer.render(ResponseKey.activityRecent))

        // Screen awareness
        case .whatAmILookingAt, .summariseScreen, .captureScreen:
            await handleScreenCapture()
        case .readMyScreen:
            await handleScreenCapture(announce: true)
        case .whatAppAmIUsing:
            let app = state.activeApp.isEmpty
                ? (context.snapshot.activeAppName.isEmpty ? "unknown" : context.snapshot.activeAppName)
                : state.activeApp
            if app == "unknown" {
                await handleScreenCapture(announce: false)
                let detected = state.screenSummary.appName
                if detected.isEmpty {
                    speak(renderer.render(ResponseKey.appIdentifyFailed))
                } else {
                    speak(renderer.render(ResponseKey.screenAppName, ["app": detected]))
                }
            } else {
                speak(renderer.render(ResponseKey.screenAppName, ["app": app]))
            }
        case .whatTextDoYouSee:
            await handleScreenCapture(announce: false)
            let lines = state.screenSummary.recognizedText
            if lines.isEmpty {
                speak(renderer.render(ResponseKey.screenTextEmpty))
            } else {
                let joined = lines.prefix(5).joined(separator: ", ")
                speak(renderer.render(ResponseKey.screenTextFound, ["text": joined]))
            }
        case .watchThisScreen:
            startScreenWatch()
            showToast("Screen watch started", icon: "eye.fill")
            speak(renderer.render(ResponseKey.screenWatchStarted))
        case .stopWatchingScreen:
            stopScreenWatch()
            showToast("Screen watch stopped", icon: "eye.slash")
            speak(renderer.render(ResponseKey.screenWatchStopped))
        case .showScreenOverlay:
            overlayManager.open(.screen)
            state.sessionLastOverlayKind = .screen

        // Ambient Context
        case .whatAmIWorkingOn:
            let ctx = ambientContext.context
            let threadSummary = taskThreadEngine.lastWorkSummary
            // Enrich with graph-stable project focus (Sprint W)
            let graphSummary = FocusContextResponder.workingSummary(
                graphIndex: contextGraph, threadEngine: taskThreadEngine, concise: true)
            let focusPrefix = graphSummary.isEmpty ? "" : graphSummary + " "
            if ctx.latestSummary.isRedacted {
                speak("Context is private for the current app.")
            } else if ctx.latestSummary.detectedTask.isEmpty && ctx.activeApp.isEmpty {
                if !focusPrefix.isEmpty {
                    speak(focusPrefix + (threadSummary.isEmpty ? "" : threadSummary))
                } else if !threadSummary.isEmpty {
                    speak(threadSummary)
                } else {
                    speak(renderer.render(ResponseKey.ambientWorkingOnUnknown))
                }
            } else {
                let task = ctx.latestSummary.detectedTask.isEmpty
                    ? "using \(ctx.activeApp.name)"
                    : ctx.latestSummary.detectedTask
                let base = renderer.render(ResponseKey.ambientWorkingOn, ["task": task])
                let full = threadSummary.isEmpty ? base : base + " " + threadSummary
                speak(focusPrefix + full)
            }
        case .whatFailedOnScreen:
            let errors = ambientContext.context.latestSummary.visibleErrors
            if errors.isEmpty {
                // Force a fresh snapshot in case errors just appeared
                let summary = await ambientContext.forceSnapshot()
                if summary.visibleErrors.isEmpty {
                    speak(renderer.render(ResponseKey.ambientNoErrors))
                } else {
                    let joined = summary.visibleErrors.prefix(3).joined(separator: ". ")
                    speak(renderer.render(ResponseKey.ambientErrors, ["errors": joined]))
                }
            } else {
                let joined = errors.prefix(3).joined(separator: ". ")
                speak(renderer.render(ResponseKey.ambientErrors, ["errors": joined]))
            }
        case .whatChangedOnScreen:
            let prevTask = ambientContext.context.latestSummary.detectedTask
            let summary = await ambientContext.forceSnapshot()
            let newTask = summary.detectedTask
            if prevTask.isEmpty || newTask.isEmpty || prevTask == newTask {
                speak(renderer.render(ResponseKey.ambientNoChange))
            } else {
                speak(renderer.render(ResponseKey.ambientChanged, ["change": newTask]))
            }
        case .watchThis:
            let appName = ambientContext.context.activeApp.name
            ambientContext.activateWatchMode(targetApp: appName.isEmpty ? nil : appName)
            showToast("Watch mode on", icon: "eye.fill")
            let app = appName.isEmpty ? "the current window" : appName
            speak(renderer.render(ResponseKey.ambientWatchStarted, ["app": app]))
        case .stopWatching:
            ambientContext.deactivateWatchMode()
            showToast("Watch mode off", icon: "eye.slash")
            speak(renderer.render(ResponseKey.ambientWatchStopped))
        case .enableAmbientContext:
            ambientContext.setEnabled(true)
            speak(renderer.render(ResponseKey.ambientEnabled))
        case .disableAmbientContext:
            ambientContext.setEnabled(false)
            speak(renderer.render(ResponseKey.ambientDisabled))
        case .showAmbientContextOverlay:
            overlayManager.open(.ambientContext)
            state.sessionLastOverlayKind = .ambientContext

        case .showRuntimeDiagnostics:
            overlayManager.open(.runtimeDiagnostics)
            state.sessionLastOverlayKind = .runtimeDiagnostics

        // Focus awareness (Sprint W)
        case .showFocus:
            openOverlay(.runtimeDiagnostics)
            state.sessionLastOverlayKind = .runtimeDiagnostics
            let summary = FocusContextResponder.workingSummary(
                graphIndex: contextGraph, threadEngine: taskThreadEngine, concise: true)
            speak(summary.isEmpty ? renderer.render(ResponseKey.showFocus) : summary)

        case .explainCurrentFocus:
            let explanation = FocusContextResponder.whyFocused(graphIndex: contextGraph)
            speak(explanation)

        case .playPingPong:
            openOverlay(.pingPong)
            speak(renderer.render(ResponseKey.playPingPong))

        case .showBrainOverlay:
            openOverlay(.brain)
            speak(renderer.render(ResponseKey.brainOverlayOpened))

        case .brainSummaryToday:
            let summary = await EpisodeStore.shared.todaysSummary()
            speak(renderer.render(ResponseKey.brainSummaryToday, ["summary": summary]))

        case .brainSummaryWeek:
            let summary = await EpisodeStore.shared.weekSummary()
            speak(renderer.render(ResponseKey.brainSummaryWeek, ["summary": summary]))

        case .showSpatialInteraction:
            // Spatial layer is always ambient — open diagnostics overlay instead.
            openOverlay(.spatialHUD)
            speak(renderer.render(ResponseKey.spatialInteractionOpen))

        case .hideSpatialInteraction:
            // Toggle spatial layer off. Cursor and HUD will fade out.
            spatialCoordinator.isEnabled = false
            _ = overlayManager.close(.spatialHUD)
            speak(renderer.render(ResponseKey.spatialInteractionClose))

        case .showCameraOverlay:
            if overlayManager.isOpen(.camera) {
                overlayManager.focus(.camera)
                speak(renderer.render(ResponseKey.cameraOverlayAlready))
            } else {
                overlayManager.open(.camera)
                state.sessionLastOverlayKind = .camera
                showToast("Showing camera", icon: "camera.fill")
                speak(renderer.render(ResponseKey.cameraOverlayOpen))
            }

        case .showHomeOverlay:
            openOverlay(.home)
            speak(renderer.render(ResponseKey.homeOverlayOpened))

        case .showCalendarOverlay:
            openOverlay(.calendar)
            speak(renderer.render(ResponseKey.calendarOverlayOpened))

        case .showTasksOverlay:
            openOverlay(.tasks)
            speak(renderer.render(ResponseKey.tasksOverlayOpened))

        // MARK: - GitHub — see GitHubIntentHandler.swift

        case .showGitHubOverlay, .checkGitHub, .githubDashboard,
             .githubListPRs, .githubReviewPR, .githubOpenPR, .githubStalePRs,
             .githubListIssues, .githubStaleIssues, .githubCreateIssue,
             .githubRecentCommits, .githubChangesToday, .githubChangesSince,
             .githubCheckCI, .githubListMyRepos, .githubActiveRepos,
             .githubNeglectedRepos, .githubCreateRepo, .githubDescribeRepo,
             .githubProjectStatus, .githubCodeReview, .githubSummariseDiff,
             .githubLocalStats:
            gitHubIntentHandler.handle(intent)

        // MARK: Shopify — see ShopifyIntentHandler.swift

        case .showShopifyOverlay, .shopifyOrders, .shopifyRevenue, .shopifyFulfilment, .shopifyStatus:
            shopifyIntentHandler.handle(intent)

        // MARK: Obsidian

        case .showObsidianOverlay:
            openOverlay(.obsidian)
            speak(renderer.render(ResponseKey.obsidianOverlay))

        case .recentObsidianNotes:
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                let notes = obsidianVault.recentNotes(limit: 5)
                if notes.isEmpty {
                    await MainActor.run { self.speak(self.renderer.render(ResponseKey.obsidianNoResults)) }
                } else {
                    let titles = notes.prefix(5).map { $0.title }.joined(separator: ", ")
                    await MainActor.run {
                        self.speak(self.renderer.render(ResponseKey.obsidianRecentNotes, ["notes": titles]))
                    }
                }
                await MainActor.run { self.openOverlay(.obsidian) }
            }

        case .searchObsidian(let query):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                let results = await obsidianVault.hybridSearch(query: query, limit: 5)
                await MainActor.run {
                    if results.isEmpty {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoResults))
                    } else {
                        let titles = results.map { $0.title }.joined(separator: ", ")
                        self.speak(self.renderer.render(ResponseKey.obsidianSearchResult, [
                            "count": "\(results.count)",
                            "query": query,
                            "titles": titles
                        ]))
                        self.openOverlay(.obsidian)
                    }
                }
            }

        case .openObsidianNote(let query):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                let results = await obsidianVault.hybridSearch(query: query, limit: 1)
                await MainActor.run {
                    if results.isEmpty {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteNotFound, ["title": query]))
                    } else {
                        self.speak(self.renderer.render(ResponseKey.obsidianSearchResult, [
                            "count": "1",
                            "query": query,
                            "titles": results[0].title
                        ]))
                        self.openOverlay(.obsidian)
                    }
                }
            }

        case .readObsidianNote(let query):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                let results = await obsidianVault.hybridSearch(query: query, limit: 1)
                await MainActor.run {
                    if let note = results.first {
                        let snippet = String(note.body.prefix(400))
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteRead, [
                            "title": note.title,
                            "content": snippet
                        ]))
                        self.openOverlay(.obsidian)
                    } else {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteNotFound, ["title": query]))
                    }
                }
            }

        case .createObsidianNote(let title, let content):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                do {
                    try await obsidianVault.createNote(title: title, content: content)
                    await MainActor.run {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteCreated, ["title": title]))
                    }
                } catch {
                    await MainActor.run {
                        self.speak("Sorry, I couldn't create that note. \(error.localizedDescription)")
                    }
                }
            }

        case .appendToObsidianNote(let title, let content):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                do {
                    try await obsidianVault.appendToNote(matching: title, text: content)
                    await MainActor.run {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteAppended, ["title": title]))
                    }
                } catch {
                    await MainActor.run {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoteNotFound, ["title": title]))
                    }
                }
            }

        case .obsidianNotesTagged(let tag):
            guard prefs.current.obsidianVaultPath != nil else {
                speak(renderer.render(ResponseKey.obsidianNotConfigured)); return
            }
            Task {
                let results = await obsidianVault.hybridSearch(query: "#\(tag)", limit: 5)
                await MainActor.run {
                    if results.isEmpty {
                        self.speak(self.renderer.render(ResponseKey.obsidianNoResults))
                    } else {
                        let titles = results.map { $0.title }.joined(separator: ", ")
                        self.speak(self.renderer.render(ResponseKey.obsidianSearchResult, [
                            "count": "\(results.count)",
                            "query": tag,
                            "titles": titles
                        ]))
                        self.openOverlay(.obsidian)
                    }
                }
            }

        case .whatDoIKnowAbout(let topic):
            Task {
                // Pull from both memory store and Obsidian vault for richest answer
                var contextParts: [String] = []
                if let svc = search {
                    let memResults = await svc.hybridSearch(query: topic, limit: 3)
                    let memTexts = memResults.filter { $0.kind == .memory }.map { "- \($0.text)" }
                    if !memTexts.isEmpty {
                        contextParts.append("From memory:\n" + memTexts.joined(separator: "\n"))
                    }
                }
                if let vaultCtx = await obsidianVault.contextForLLM(
                    query: topic,
                    maxNotes: prefs.current.obsidianMaxContextNotes,
                    maxCharsPerNote: 600
                ) {
                    contextParts.append(vaultCtx)
                }
                let combined = contextParts.joined(separator: "\n\n")
                if combined.isEmpty {
                    await MainActor.run {
                        self.speak("I don't have any notes or memories about \(topic) yet.")
                    }
                } else {
                    // Ask LLM to synthesise
                    let req = LLMRequest(
                        systemPrompt: "You are a knowledgeable assistant. Summarise what is known about the topic from the provided context. Be concise — 2-3 sentences maximum.",
                        userPrompt: "What do I know about \(topic)?",
                        contextSummary: combined,
                        temperature: 0.3,
                        maxTokens: 200,
                        responseFormat: .text,
                        timeoutSeconds: 8
                    )
                    do {
                        let result = try await llmRouter.complete(req, circuitBreaker: circuitBreaker)
                        await MainActor.run {
                            self.speak(result.text)
                        }
                    } catch {
                        await MainActor.run {
                            self.speak("Here's what I found about \(topic): \(combined.prefix(300))")
                        }
                    }
                }
            }

        case .hideCamera:
            if overlayManager.close(.camera) {
                if state.sessionLastOverlayKind == .camera {
                    state.sessionLastOverlayKind = nil
                }
                showToast("Camera closed", icon: "camera.fill")
                speak(renderer.render(ResponseKey.cameraOverlayClosed))
            } else {
                speak(renderer.render(ResponseKey.cameraOverlayAlreadyClosed))
            }

        case .hideNews:
            // Close + reset news state.  `LiveNewsPlayerView.dismantleNSView`
            // takes care of stopping the video, blanking the WKWebView,
            // and releasing the render process — see that file for the
            // teardown details.  Here we make sure listening can resume.
            if overlayManager.close(.news) {
                if state.sessionLastOverlayKind == .news {
                    state.sessionLastOverlayKind = nil
                }
                state.newsLivePlayerVisible = false
                state.newsOverlayMode = .headlines
                exitMediaPlayback()
                showToast("News closed", icon: "newspaper.fill")
                speak(renderer.render(ResponseKey.newsClosed))
            } else {
                speak(renderer.render(ResponseKey.newsAlreadyClosed))
            }

        // Sanity-check / small talk
        case .canYouHearMe:
            speak(renderer.render(ResponseKey.hearingConfirm))
        case .areYouListening:
            speak(renderer.render(ResponseKey.listeningConfirm))

        // Always-on listening lifecycle
        case .disableListening:
            disableListening()
        case .enableListening:
            enableListening()

        // Time
        case .tellTime:
            let f = DateFormatter()
            f.locale = Locale.current
            f.dateFormat = "h:mm a"
            let stamp = f.string(from: Date())
            speak(renderer.render(ResponseKey.timeNow, ["time": stamp]))

        case .tellDate:
            let f = DateFormatter()
            f.locale = Locale.current
            f.dateStyle = .full
            f.timeStyle = .none
            speak(renderer.render(ResponseKey.dateToday, ["date": f.string(from: Date())]))

        // UI mode — these no longer switch full-screen views; Jarvis uses a
        // single stage. Developer mode opens the Debug HUD overlay instead.
        case .developerMode:
            state.debugHUDVisible = true
            showToast("Debug HUD")
            speak(renderer.render(ResponseKey.developerModeOn))

        case .workspaceMode:
            overlayManager.closeAll()
            showToast("Workspace mode")
            speak(renderer.render(ResponseKey.workspaceMode))

        // Proactivity
        case .showNotifications:
            overlayManager.open(.notifications)
            let count = proactivity.pendingCount
            if count == 0 {
                speak(renderer.render(ResponseKey.notificationsNone))
            } else {
                speak(renderer.render(ResponseKey.notificationsPending,
                                      ["count": "\(count)",
                                       "count_label": count == 1 ? "notification" : "notifications"]))
            }

        case .dismissNotifications:
            proactivity.dismissAll()
            overlayManager.close(.notifications)
            speak(renderer.render(ResponseKey.notificationsCleared))

        case .pauseProactivity:
            proactivity.pause()
            speak(renderer.render(ResponseKey.proactivityPaused))

        case .resumeProactivity:
            proactivity.resume()
            speak(renderer.render(ResponseKey.proactivityResumed))

        case .muteNewsForHour:
            proactivity.mute(.news, for: 3600)
            speak(renderer.render(ResponseKey.newsNotifsMutedHour))

        case .muteNews:
            proactivity.mute(.news, for: .infinity)
            speak(renderer.render(ResponseKey.newsNotifsMuted))

        case .unmuteNews:
            proactivity.unmute(.news)
            speak(renderer.render(ResponseKey.newsNotifsUnmuted))

        case .openThatStory:
            // Prefer the latest proactive presentation (works for any source),
            // then fall back to news-article lookup for backwards compatibility.
            if let presentation = proactivity.latestPresentation {
                overlayManager.open(presentation.overlayKind)
                if presentation.overlayKind == .news,
                   let articleID = presentation.highlightItemID {
                    Task {
                        if let article = await newsStore.article(id: articleID) {
                            openArticle(article)
                        }
                    }
                }
                speak(renderer.render(ResponseKey.proactivityOpening,
                                      ["source": presentation.signal.source.displayName]))
            } else if let signal = proactivity.lastSpokenSignal,
                      let articleID = signal.sourceArticleID {
                Task {
                    if let article = await newsStore.article(id: articleID) {
                        openArticle(article)
                        overlayManager.open(.news)
                    } else {
                        speak(renderer.render(ResponseKey.proactivityStoryNotFound))
                    }
                }
            } else {
                speak(renderer.render(ResponseKey.proactivityNothingRecent))
            }

        case .showLatestAlert:
            if let presentation = proactivity.latestPresentation {
                overlayManager.open(presentation.overlayKind)
                speak(renderer.render(ResponseKey.proactivityOpening,
                                      ["source": presentation.signal.source.displayName]))
            } else {
                speak(renderer.render(ResponseKey.proactivityNothingFlagged))
            }

        case .dismissLatestAlert:
            if let presentation = proactivity.latestPresentation {
                proactivity.dismiss(presentation.signal.id)
                // Persist dismissal so the same story is suppressed on next launch.
                proactiveNotificationStore.markDismissed(presentation.signal.dedupeKey)
                // Close the proactiveAlert overlay if it was opened for this signal.
                if presentation.overlayKind == .proactiveAlert {
                    overlayManager.close(.proactiveAlert)
                }
                showToast("Dismissed", icon: "xmark.circle.fill")
                speak(renderer.render(ResponseKey.proactivityDismissed))
            } else if let signal = proactivity.lastSpokenSignal {
                proactivity.dismiss(signal.id)
                proactiveNotificationStore.markDismissed(signal.dedupeKey)
                showToast("Dismissed", icon: "xmark.circle.fill")
                speak(renderer.render(ResponseKey.proactivityDismissed))
            } else {
                speak(renderer.render(ResponseKey.proactivityNothingToDismiss))
            }

        case .summariseThat:
            if let signal = proactivity.lastSpokenSignal,
               let articleID = signal.sourceArticleID {
                Task {
                    if let article = await newsStore.article(id: articleID) {
                        let text = article.summary.isEmpty ? article.contentExcerpt : article.summary
                        if text.isEmpty {
                            speak(renderer.render(ResponseKey.proactivityNoSummary))
                        } else {
                            let excerpt = shortSpeechExcerpt(text, maxChars: 200)
                            speak(renderer.render(ResponseKey.proactivitySummary, ["excerpt": excerpt]))
                        }
                    } else {
                        speak(renderer.render(ResponseKey.proactivityStoryNotFound))
                    }
                }
            } else {
                speak(renderer.render(ResponseKey.proactivityConfused))
            }

        case .proactivityUseful:
            proactivity.recordUseful()
            speak(renderer.render(ResponseKey.proactivityPosFeedback))

        case .proactivityNotUseful:
            proactivity.recordNotUseful()
            speak(renderer.render(ResponseKey.proactivityNegFeedback))

        case .neverTellMeAboutThis:
            proactivity.neverTellAboutThis()
            if let signal = proactivity.lastSpokenSignal {
                let cat = signal.category.isEmpty ? "that" : signal.category
                speak(renderer.render(ResponseKey.proactivityPrefSet,
                                      ["category": cat, "source": signal.source.displayName]))
            } else {
                speak(renderer.render(ResponseKey.proactivityPrefGeneric))
            }

        case .alwaysTellMeAboutThis:
            proactivity.alwaysTellAboutThis()
            if let signal = proactivity.lastSpokenSignal {
                let cat = signal.category.isEmpty ? "those" : signal.category
                speak(renderer.render(ResponseKey.proactivityPrefPriority,
                                      ["category": cat, "source": signal.source.displayName]))
            } else {
                speak(renderer.render(ResponseKey.proactivityPrefPriorityGeneric))
            }

        // MARK: macOS System Control — App management

        case .activateApp(let name):
            if systemController.activateApp(named: name) {
                speak(renderer.render(ResponseKey.appActivated, ["app": name]))
            } else {
                // App not running — try opening it
                let result = await systemController.openApp(named: name)
                handleAppOpenResult(result, query: name)
            }

        case .hideApp(let name):
            if systemController.hideApp(named: name) {
                speak(renderer.render(ResponseKey.appHidden, ["app": name]))
            } else {
                speak(renderer.render(ResponseKey.appNotFound, ["app": name]))
            }

        case .quitApp(let name):
            if systemController.quitApp(named: name) {
                speak(renderer.render(ResponseKey.appQuit, ["app": name]))
            } else {
                speak(renderer.render(ResponseKey.appNotFound, ["app": name]))
            }

        case .listRunningApps:
            let appList = systemController.listRunningApps()
            if appList.isEmpty {
                speak(renderer.render(ResponseKey.appsNoneRunning))
            } else {
                let preview = appList.prefix(8).joined(separator: ", ")
                let total   = appList.count
                let suffix  = total > 8 ? ", and \(total - 8) more" : ""
                speak(renderer.render(ResponseKey.appsRunning,
                                      ["apps": preview + suffix]))
            }

        // MARK: macOS System Control — System Settings

        case .openSystemSettings(let pane):
            let result = systemController.openSystemSettings(pane: pane)
            switch result {
            case .openedPane(let p):
                let displayName = p.split(separator: " ").map(\.capitalized).joined(separator: " ")
                speak(renderer.render(ResponseKey.settingsPaneOpened, ["pane": displayName]))
            case .openedGeneral:
                speak(renderer.render(ResponseKey.settingsOpened))
            case .error(let err):
                state.log("system", .warn, "settings_open_error: \(err)")
                speak(renderer.render(ResponseKey.settingsOpenFailed))
            }

        // MARK: macOS System Control — Volume

        case .volumeUp:
            let vol = systemController.volumeUp()
            speak(renderer.render(ResponseKey.volumeUp, ["level": "\(vol.level)"]))

        case .volumeDown:
            let vol = systemController.volumeDown()
            speak(renderer.render(ResponseKey.volumeDown, ["level": "\(vol.level)"]))

        case .mute:
            systemController.mute()
            speak(renderer.render(ResponseKey.volumeMuted))

        case .unmute:
            systemController.unmute()
            speak(renderer.render(ResponseKey.volumeUnmuted))

        case .setVolume(let level):
            let vol = systemController.setVolume(level)
            speak(renderer.render(ResponseKey.volumeSet, ["level": "\(vol.level)"]))

        case .getVolume:
            if let vol = systemController.getVolume() {
                let state2 = vol.isMuted ? "muted" : "\(vol.level)%"
                speak(renderer.render(ResponseKey.volumeCurrent, ["level": state2]))
            } else {
                speak(renderer.render(ResponseKey.volumeReadFailed))
            }

        // MARK: macOS System Control — Files & Folders

        case .openFolder(let name):
            let result = systemController.openFolder(named: name)
            switch result {
            case .opened(let n):
                let display = n.split(separator: " ").map(\.capitalized).joined(separator: " ")
                speak(renderer.render(ResponseKey.folderOpened, ["folder": display]))
            case .notFound(let n):
                speak(renderer.render(ResponseKey.folderNotFound, ["folder": n]))
            }

        case .openLatestDownload:
            if let file = systemController.openLatestDownload() {
                speak(renderer.render(ResponseKey.latestDownload,
                                      ["file": file.displayName]))
            } else {
                speak(renderer.render(ResponseKey.latestDownloadNone))
            }

        case .findFile(let query):
            showToast("Searching for \(query)…", icon: "magnifyingglass")
            let results = systemController.searchFiles(query: query)
            if results.isEmpty {
                speak(renderer.render(ResponseKey.fileSearchEmpty, ["query": query]))
            } else {
                let label = results.count == 1 ? "" : "s"
                speak(renderer.render(ResponseKey.fileSearchResults,
                                      ["count": "\(results.count)",
                                       "count_label": label,
                                       "query": query]))
                if results.count == 1, let first = results.first {
                    // Single result — open it automatically
                    systemController.openFile(path: first.path)
                } else {
                    // Multiple results — show the interactive search overlay
                    state.fileSearchResults = results
                    state.fileSearchQuery   = query
                    withAnimation(.spring(duration: 0.28, bounce: 0.12)) {
                        state.fileSearchOverlayVisible = true
                    }
                }
            }

        case .revealInFinder(let path):
            systemController.revealInFinder(path: path)
            speak(renderer.render(ResponseKey.finderRevealed))

        // MARK: macOS System Control — Windows

        case .showDesktop:
            if systemController.hasAccessibilityPermission {
                systemController.showDesktop()
                speak(renderer.render(ResponseKey.desktopShown))
            } else {
                speak(renderer.render(ResponseKey.accessibilityNeeded))
            }

        case .lockScreen:
            systemController.lockScreen()
            speak(renderer.render(ResponseKey.screenLocked))

        case .sleepDisplay:
            systemController.sleepDisplay()
            speak(renderer.render(ResponseKey.displaySlept))

        // MARK: macOS System Control — Connectivity Toggles

        case .wifiOn:
            speak(renderer.render(ResponseKey.wifiEnabled))
            systemController.setWifi(on: true)

        case .wifiOff:
            speak(renderer.render(ResponseKey.wifiDisabled))
            systemController.setWifi(on: false)

        case .bluetoothOn:
            speak(renderer.render(ResponseKey.bluetoothEnabled))
            systemController.setBluetooth(on: true)

        case .bluetoothOff:
            speak(renderer.render(ResponseKey.bluetoothDisabled))
            systemController.setBluetooth(on: false)

        // MARK: - Weather — see WeatherIntentHandler.swift

        case .currentWeather, .weatherForecast:
            await weatherIntentHandler.handle(intent)

        case .jarvisHelp:
            // Legacy capabilities intent — now routed through the same
            // living-documentation overlay as `.showHelp` so "what can
            // you do" / "help" / "list commands" all surface the actual
            // current set of enabled features instead of a canned
            // sentence.  Keeping the case (vs collapsing to .showHelp)
            // preserves the phrase-store mapping and IntentRouter
            // substring fallback while fixing the user-visible
            // behaviour.
            openOverlay(.help)
            let helpEngine = LivingDocumentationEngine.shared
            let helpCount  = helpEngine.allSections().count
            let helpCats   = helpEngine.nonEmptyCategories().count
            speak("Here's what I can do.  \(helpCount) topics across \(helpCats) sections, all reflecting your current setup.  Use the search box to find something specific.")

        case .dailyBriefing:
            var briefingParts: [String] = []
            // News
            let topHeadlines = newsStore.articles.prefix(3)
            if !topHeadlines.isEmpty {
                let titles = topHeadlines.map(\.title).joined(separator: "; ")
                briefingParts.append("Top news: \(titles)")
            }
            // Calendar
            if calendarService.isAuthorized {
                let (count, calSummary) = calendarService.spokenSummaryToday()
                if count > 0 { briefingParts.append("Calendar: \(calSummary)") }
            }
            // Todoist
            if let todoist = todoistClient,
               let tasks = try? await todoist.getTasks(), !tasks.isEmpty {
                let overdue = tasks.filter(\.isOverdue)
                if !overdue.isEmpty {
                    briefingParts.append("\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s") in Todoist")
                } else {
                    briefingParts.append("\(tasks.count) task\(tasks.count == 1 ? "" : "s") in Todoist")
                }
            }
            // Weather
            if weatherService.isAuthorized {
                let wx = await weatherService.spokenCurrentWeather()
                briefingParts.append("Weather: \(wx)")
            }
            if briefingParts.isEmpty {
                speak(renderer.render(ResponseKey.dailyBriefingEmpty))
            } else {
                speak(renderer.render(ResponseKey.dailyBriefing, ["summary": briefingParts.joined(separator: ". ")]))
            }

        // MARK: - Timer & Stopwatch
        case .setTimer(let seconds, let name):
            let timer = timerService.setTimer(name: name, seconds: seconds)
            let totalSecs = Int(seconds)
            let hrs = totalSecs / 3600
            let mins = (totalSecs % 3600) / 60
            let secs = totalSecs % 60
            var parts: [String] = []
            if hrs > 0  { parts.append("\(hrs) hour\(hrs == 1 ? "" : "s")") }
            if mins > 0 { parts.append("\(mins) minute\(mins == 1 ? "" : "s")") }
            if secs > 0 { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
            let durationStr = parts.isEmpty ? "\(totalSecs) seconds" : parts.joined(separator: " ")
            _ = timer  // suppress unused warning
            speak(renderer.render(ResponseKey.timerSet, ["duration": durationStr]))

        case .cancelTimer(let name):
            if let n = name {
                let cancelled = timerService.cancelTimer(named: n)
                if cancelled {
                    speak(renderer.render(ResponseKey.timerCancelled, ["name": n]))
                } else {
                    speak("I couldn't find a timer called \(n).")
                }
            } else if let active = timerService.firstActive() {
                timerService.cancelTimer(named: active.name)
                speak(renderer.render(ResponseKey.timerCancelled, ["name": active.name]))
            } else {
                speak(renderer.render(ResponseKey.timerNone, [:]))
            }

        case .cancelAllTimers:
            timerService.cancelAllTimers()
            speak("All timers cancelled.")

        case .timerStatus:
            let active = timerService.activeTimers()
            if active.isEmpty {
                speak(renderer.render(ResponseKey.timerNone, [:]))
            } else {
                let t = active[0]
                speak(renderer.render(ResponseKey.timerStatus,
                                      ["name": t.name, "remaining": t.displayRemaining]))
            }

        case .startStopwatch:
            timerService.startStopwatch()
            speak(renderer.render(ResponseKey.stopwatchStarted, [:]))

        case .stopStopwatch:
            timerService.stopStopwatchTimer()
            speak(renderer.render(ResponseKey.stopwatchStopped,
                                  ["elapsed": timerService.stopwatch.displayElapsed]))

        case .stopwatchStatus:
            if timerService.stopwatch.startedAt != nil {
                speak(renderer.render(ResponseKey.stopwatchStatus,
                                      ["elapsed": timerService.stopwatch.displayElapsed]))
            } else {
                speak("The stopwatch isn't running.")
            }

        // MARK: - Clipboard
        case .clipboardRead:
            if let text = systemController.readClipboard(), !text.isEmpty {
                let preview = String(text.prefix(100))
                speak(renderer.render(ResponseKey.clipboardContent, ["text": preview]))
            } else {
                speak(renderer.render(ResponseKey.clipboardEmpty, [:]))
            }

        case .clipboardCopy:
            let lastResponse = state.lastSpoken
            if !lastResponse.isEmpty {
                systemController.writeClipboard(lastResponse)
                speak(renderer.render(ResponseKey.clipboardCopied, [:]))
            } else {
                speak("Nothing to copy yet.")
            }

        // MARK: - Spotify — see SpotifyIntentHandler.swift

        case .spotifyPlay, .spotifyPause, .spotifyResume, .spotifyNext,
             .spotifyPrevious, .spotifyWhatIsPlaying, .spotifyVolume, .spotifyShuffle:
            spotifyIntentHandler.handle(intent)

        // MARK: - Android Bridge

        case .showAndroidOverlay:
            // If a call is active/ringing, open the Phone overlay instead
            if !state.activeCallState.isEmpty {
                openOverlay(.phone)
            } else {
                openOverlay(.androidBridge)
            }
            speak(renderer.render(ResponseKey.androidStatus,
                                  ["connected": androidBridge?.diagnostics.isConnected == true ? "connected" : "offline",
                                   "device_info": androidBridge?.diagnostics.deviceName ?? ""]))

        case .androidBridgeStatus:
            let diag = androidBridge?.diagnostics ?? AndroidBridgeDiagnostics()
            if diag.isConnected {
                let info = diag.deviceName.isEmpty ? "Android device" : diag.deviceName
                let batt = diag.batteryLevel >= 0 ? ", battery \(diag.batteryLevel)%" : ""
                speak("Phone connected: \(info)\(batt).")
            } else {
                speak(renderer.render(ResponseKey.androidPhoneOffline, [:]))
            }

        case .phoneBattery:
            // Answered ENTIRELY from the latest heartbeat cache — no LLM,
            // no web search, no unknown fallback.  The brief insists this
            // path stay local because the data is local.
            let diag = androidBridge?.diagnostics ?? AndroidBridgeDiagnostics()
            let device = diag.deviceName.isEmpty ? "phone" : diag.deviceName
            if !diag.isConnected {
                speak(renderer.render(ResponseKey.phoneBatteryOffline, [
                    "last_seen": diag.lastSeenDescription(),
                ]))
            } else if diag.batteryLevel < 0 {
                // Connected but no battery yet — first heartbeat hasn't
                // landed.  Surface explicitly rather than guessing.
                speak("Your \(device) is connected but hasn't reported a battery level yet.")
            } else {
                let percent = String(diag.batteryLevel)
                let key: String
                switch diag.isCharging {
                case .some(true):  key = ResponseKey.phoneBatteryCharging
                case .some(false): key = ResponseKey.phoneBatteryDischarging
                case .none:        key = ResponseKey.phoneBatteryUnknown
                }
                speak(renderer.render(key, [
                    "device":  device,
                    "percent": percent,
                    "network": diag.network,
                ]))
            }
            // Push to ActiveContextRegistry so a follow-up "is it charging?"
            // resolves against the most recent reading.
            activeContext.record(
                source: .androidNotification,
                title: "Phone status",
                summary: "Battery \(diag.batteryLevel)%, charging=\(diag.isCharging.map(String.init(describing:)) ?? "?"), network=\(diag.network)",
                priority: 1,
                suggestedActions: [.describeMore])

        case .callContact(let name):
            Task {
                await executeCallContact(name: name)
            }

        case .sendSMS(let recipient, let message):
            Task {
                await executeSendSMS(recipient: recipient, message: message)
            }

        case .sendWhatsApp(let recipient, let message):
            Task {
                await executeSendWhatsApp(recipient: recipient, message: message)
            }

        case .findContact(let query):
            Task {
                await executeFindContact(query: query)
            }

        case .ringPhone:
            Task {
                guard requirePhoneOnline() else { return }
                speak(renderer.render(ResponseKey.androidRinging, [:]))
                _ = await androidBridge?.sendToAndroid(
                    command: "ring_phone",
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
            }

        case .phoneLocation:
            Task {
                guard requirePhoneOnline() else { return }
                let response = await androidBridge?.sendToAndroid(
                    command: "phone_location",
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
                if response?.ok == true {
                    speak(response?.message ?? "Location sent to your phone.")
                } else {
                    handleAndroidError(response)
                }
            }

        case .startNavigation(let destination):
            Task {
                guard requirePhoneOnline() else { return }
                // Empty destination — ask for it via conversational follow-up
                guard !destination.isEmpty else {
                    speak("Where would you like me to navigate to?")
                    activePendingContext = PendingConversationContext.make(
                        originalTranscript: state.lastFinalTranscript,
                        originalIntent: .startNavigation(destination: ""),
                        assistantQuestion: "Where would you like me to navigate to?",
                        responseType: .freeform,
                        onFreeform: .callLLMWithHistory
                    )
                    return
                }
                speak(renderer.render(ResponseKey.androidNavigating, ["destination": destination]))
                let payload = AndroidCommandPayload(destination: destination)
                let response = await androidBridge?.sendToAndroid(
                    command: "start_navigation", payload: payload,
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
                if let response, !response.ok { handleAndroidError(response) }
            }

        case .readNotifications:
            Task {
                guard requirePhoneOnline() else { return }
                let response = await androidBridge?.sendToAndroid(
                    command: "read_notifications",
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
                if response?.ok == true {
                    let count = response?.payload?.notificationCount ?? 0
                    let text = response?.payload?.notificationText ?? response?.message ?? "Nothing new."
                    speak(renderer.render(ResponseKey.androidNotificationsRead,
                                          ["count": "\(count)", "text": text]))
                } else {
                    handleAndroidError(response)
                }
            }

        case .queryNotification(let app):
            Task {
                guard requirePhoneOnline() else { return }
                let payload = AndroidCommandPayload(app: app)
                let response = await androidBridge?.sendToAndroid(
                    command: "query_notification", payload: payload,
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
                if response?.status == AndroidResponseStatus.permissionRequired {
                    speak(renderer.render(ResponseKey.androidNeedsPermission, [:]))
                } else if let text = response?.payload?.notificationText, !text.isEmpty {
                    speak(text)
                } else {
                    speak(response?.message ?? "Nothing from \(app).")
                }
            }

        case .capturePhoneCamera:
            Task {
                guard requirePhoneOnline() else { return }
                speak("Capturing from your phone camera.")
                let response = await androidBridge?.sendToAndroid(
                    command: "capture_camera",
                    transcript: state.lastFinalTranscript, sessionId: sessionId)
                if response?.status == AndroidResponseStatus.permissionRequired {
                    speak(renderer.render(ResponseKey.androidNeedsPermission, [:]))
                } else if let msg = response?.message, !msg.isEmpty {
                    speak(msg)
                } else if response?.ok != true {
                    speak(renderer.render(ResponseKey.androidCommandFailed,
                                          ["error": "No image returned from phone."]))
                }
            }

        // ── Android phone event follow-up actions ─────────────────────────
        case .callBackLastCaller:
            Task { await executeCallBackLastCaller() }

        case .replyToLastSender(let message):
            Task { await executeReplyToLastSender(message: message) }

        case .showLatestAndroidMessage:
            openOverlay(.androidBridge)
            // Speak the message if we have one in context
            if let body = androidEventReceiver?.latestMessageBody, !body.isEmpty {
                let preview = String(body.prefix(100))
                speak(preview)
            } else if let sender = androidEventReceiver?.latestWhatsAppSender
                               ?? androidEventReceiver?.latestSMSSender {
                speak("Latest message is from \(sender).")
                openOverlay(.androidBridge)
            } else {
                speak("I don't have a recent message to show.")
            }

        // ── Phase-1 remote call control ───────────────────────────────────
        case .answerCall:
            Task { await executeAnswerCall() }

        case .declineCall:
            Task { await executeDeclineCall() }

        case .hangUpCall:
            Task { await executeHangUpCall() }

        case .speakerOn:
            Task { await executeSpeakerOn() }

        case .speakerOff:
            Task { await executeSpeakerOff() }

        // MARK: - WhatsApp calls

        case .whatsAppVoiceCall(let contact):
            Task { await executeWhatsAppCall(contact: contact, video: false) }

        case .whatsAppVideoCall(let contact):
            Task { await executeWhatsAppCall(contact: contact, video: true) }

        // MARK: - Living documentation

        // MARK: - Reddit — see RedditIntentHandler.swift

        case .showReddit, .showRedditTop, .showSubreddit, .redditQuery,
             .redditOpenIndex, .redditShowComments, .redditOpenInBrowser,
             .redditSavePost, .redditSummarisePost, .redditSummariseComments,
             .redditRefresh:
            redditIntentHandler.handle(intent)

        case .showHelp:
            // Open the help overlay and speak a short summary of the
            // current state of the app.
            openOverlay(.help)
            let engine = LivingDocumentationEngine.shared
            let count = engine.allSections().count
            let cats  = engine.nonEmptyCategories().count
            speak("Here's what I can do.  \(count) topics across \(cats) sections, all reflecting your current setup.  Use the search box to find something specific.")

        case .documentationLookup(let query):
            // Pure documentation answer — never the LLM.  If the engine
            // has no hit above the confidence threshold we explicitly
            // tell the user "I don't have docs on that yet" rather than
            // hallucinating an answer.
            if let result = LivingDocumentationEngine.shared.answer(for: query) {
                openOverlay(.help)
                speak(result.spoken)
                activeContext.record(
                    source: .llmAnswer,
                    title: "Help: " + result.section.title,
                    summary: result.section.subtitle ?? result.section.title,
                    priority: 1,
                    suggestedActions: [.describeMore])
            } else {
                speak("I don't have documentation on that yet, but you can open the help overlay and search for a related topic.")
                openOverlay(.help)
            }

        case .unknown(let text):
            // Don't speak for very short or empty utterances (noise / cough).
            guard text.split(separator: " ").count > 1 else { return }
#if DEBUG
            // Routing-gap detector: if the raw text contains a domain keyword
            // that a handler should have matched, log it so we catch phrase-store
            // or LLM-mapping regressions early.  Zero overhead in Release builds.
            let domainKeywords = ["github", "reddit", "shopify", "spotify",
                                  "todoist", "calendar", "weather", "home assistant",
                                  "turn on", "turn off", "lock", "unlock", "scene",
                                  "reminder", "meeting", "forecast"]
            let lower = text.lowercased()
            if let keyword = domainKeywords.first(where: { lower.contains($0) }) {
                assertionFailure(
                    "[execute] routing gap: '\(text)' reached .unknown but contains " +
                    "domain keyword '\(keyword)' — check IntentRouter and phrase-store coverage."
                )
            }
#endif
            handleFinalUnknown(rawText: text)
        }
    }

    /// FINAL "I don't know how to do that" path.  Every other tier —
    /// command match, follow-up, active context, classified LLM, free-text
    /// LLM, search — has already declined.  Logs the event with enriched
    /// diagnostic context, optionally files a GitHub issue, and speaks a
    /// useful message (NOT the old "I don't have an action for that yet"
    /// line, which is now treated as a bug path).
    private func handleFinalUnknown(rawText: String) {
        let normalized = TranscriptNormalizer.normalize(rawText)
        let bridge = androidBridge
        let connected = bridge?.diagnostics.isConnected
        let ctxBlock = context.snapshot.summaryString()
        let lastIntentLabel = String(describing: state.lastIntent)
            .components(separatedBy: "(").first ?? ""
        let llmDecision: String? = state.llmFallbackUsed
            ? "fallback_attempted_but_unmapped"
            : nil
        let userExpected = QuestionClassifier.classify(
            rawText,
            hasPendingQuestion: activePendingContext != nil,
            hasActiveContext: !activeContext.items.isEmpty).rawValue

        // Make sure an entry exists — most of the time it was already
        // recorded at routing time (step 3 of handleTranscript), but
        // certain paths (e.g. fast-route miss + LLM unmapped without an
        // earlier .unknown record) leave the store empty.  record() is
        // dedupe-safe.
        unmatched.record(UnmatchedCommandEntry(
            rawText: rawText,
            normalizedText: normalized,
            action: nil,
            target: nil,
            targetLabel: nil,
            activeOverlay: overlayManager.latestKind?.rawValue,
            phase: state.phase.rawValue))

        // Enrich with full diagnostic context now that we know what
        // happened across the whole pipeline.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map {
            $0 + "+" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        }
        unmatched.enrich(
            normalizedText: normalized,
            currentApp: state.activeApp,
            matchedCandidate: state.phraseMatchedCommand,
            activeContext: ctxBlock,
            listeningMode: state.phase.rawValue,
            lastIntent: lastIntentLabel,
            llmDecision: llmDecision,
            androidConnected: connected,
            userExpectedAction: userExpected,
            appVersion: version)

        // Telemetry — never includes raw text or token.
        JarvisTelemetry.shared.record(.providerFailed, [
            "kind": "unknown_command_final",
            "android_connected": connected.map { $0 ? "yes" : "no" } ?? "?",
            "user_expected": userExpected,
        ])

        // Optional GitHub issue creation (dedup + cooldown enforced inside).
        let snapshot = unmatched.entry(normalizedText: normalized)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let entry = snapshot,
                  self.prefs.current.githubIssueLoggingEnabled,
                  self.prefs.current.githubIssueAutoCreate else {
                // Speak the local-only message.
                self.speak("I don't know how to do that yet. I've logged it so we can wire it in.")
                return
            }
            let result = await self.githubIssueService.createIssueIfNeeded(
                for: entry, store: self.unmatched)
            switch result {
            case .created:
                self.speak("I don't know how to do that yet. I've opened a GitHub issue for it.")
            case .skippedDuplicate:
                self.speak("I don't know how to do that yet. I've already logged it on GitHub previously.")
            case .skippedCooldown, .skippedDisabled, .skippedNotConfigured, .failed:
                self.speak("I don't know how to do that yet. I've logged it so we can wire it in.")
            }
        }
    }

    // MARK: - Tailscale

    func updateTailscaleState() {
        // refresh() fires a background Task and returns the cached status immediately.
        // AppState is updated once the background scan finishes via MainActor.run.
        tailscale.refresh()
        // Sync whatever is already cached (may be empty on first call — that's fine).
        let s = tailscale.status
        state.tailscaleIP = s.ip
        state.tailscaleHostname = s.hostname
        state.tailscaleConnected = s.isConnected
    }

    // MARK: - Mac Brain HTTP server

    func startBrainServer() {
        guard prefs.current.daemonEnabled else {
            // Daemon disabled at prefs level — start local brain-context + camera HTTP only
            // (loopback only, brain-context routes, NO external WebSocket hosting)
            _startLocalBrainContextServer()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let daemonAlive = await DaemonManager.shared.checkDaemonHealth()
            if daemonAlive {
                Log.net.info("[BrainGateway] Daemon owns port 8765 — skipping in-app server")
                self.state.daemonUnavailable = false
                return
            }
            // Daemon not running — surface diagnostic, do NOT bind port 8765
            Log.net.error("[BrainGateway] JarvisBrainDaemon is not running. Cross-device features unavailable.")
            self.state.daemonUnavailable = true
            self._startLocalBrainContextServer()
        }
    }

    private func _startLocalBrainContextServer() {
        let engine = BrainContextEngine()
        engine.memoryProvider     = MemoryContextProvider()
        engine.projectProvider    = ProjectContextProvider()
        engine.preferenceProvider = PreferenceContextProvider(prefs: prefs)
        engine.haAliasProvider    = HomeAssistantAliasProvider(aliasStore: homeAliases)

        let ghProvider = GitHubContextProvider()
        ghProvider.getNotifications = { [weak self] in self?.githubClient?.lastFetchedNotifications ?? [] }
        engine.githubProvider = ghProvider

        let interactionStore     = BrainInteractionStore()
        let correctionStore      = BrainCorrectionStore()
        let memoryCandidateStore = BrainMemoryCandidateStore()

        let handler = BrainHTTPHandler(
            contextEngine: engine,
            interactionStore: interactionStore,
            correctionStore: correctionStore,
            memoryCandidateStore: memoryCandidateStore,
            diagnostics: gatewayDiagnostics
        )

        let server = MacBrainServer(handler: handler, diagnostics: gatewayDiagnostics)

        // Wire camera routes if the camera server is enabled.
        if prefs.current.cameraServerEnabled {
            let routes = MacCameraHttpRoutes()
            routes.cameraService  = cameraService
            routes.frameStore     = cameraFrameStore
            routes.diagnostics    = cameraDiagnostics
            routes.keepCameraWarm = prefs.current.keepCameraWarm
            routes.fpsInterval    = fpsIntervalForCameraFPS(prefs.current.cameraFPS)
            let quality = jpegQualityForSetting(prefs.current.cameraJPEGQuality)
            cameraService.setQuality(quality)
            server.cameraRoutes         = routes
            server.requireCameraToken   = prefs.current.cameraServerRequireToken
            cameraDiagnostics.log(.serverEnabled)
        }

        // Local brain-context + camera HTTP only — loopback-only, no external WebSocket hosting.
        server.start(
            port: prefs.current.brainServerPort,
            bindLocalOnly: prefs.current.brainServerBindLocalOnly
        )
        brainServer = server
    }

    private func fpsIntervalForCameraFPS(_ fps: Int) -> TimeInterval {
        switch fps { case 1: return 1.0; case 10: return 0.1; default: return 0.2 }
    }

    private func jpegQualityForSetting(_ setting: String) -> CGFloat {
        switch setting { case "low": return 0.3; case "high": return 0.9; default: return 0.6 }
    }

    func stopBrainServer() {
        brainServer?.stop()
        brainServer = nil
    }

    func restartBrainServer() {
        stopBrainServer()
        startBrainServer()
    }

    // MARK: - Local Learning Engine helpers

    private func buildLocalLLMConfig() -> LocalLLMConfig {
        let p = prefs.current
        let provider = LocalLLMProvider(rawValue: p.localLLMProvider) ?? .openAICompatible
        return LocalLLMConfig(
            enabled:        p.localLLMEnabled,
            provider:       provider,
            baseURL:        p.localLLMBaseURL,
            modelName:      p.localLLMModelName,
            apiKey:         p.localLLMApiKey,
            timeoutSeconds: p.localLLMTimeoutSecs,
            maxTokens:      p.localLLMMaxTokens,
            temperature:    p.localLLMTemperature
        )
    }

    // MARK: - Android Bridge helpers

    /// Returns true if the Android phone is online; speaks the offline response and returns
    /// false if not. Call at the top of every Android execute helper.
    @discardableResult
    private func requirePhoneOnline() -> Bool {
        guard androidBridge?.isPhoneOnline == true else {
            speak(renderer.render(ResponseKey.androidPhoneOffline, [:]))
            return false
        }
        return true
    }

    /// Handle a `permission_required` or `failed` status from an Android response.
    /// Returns true if the status required speaking an error (i.e. caller should stop).
    @discardableResult
    private func handleAndroidError(_ response: AndroidResponse?) -> Bool {
        guard let response else { return false }
        if response.status == AndroidResponseStatus.permissionRequired {
            speak(renderer.render(ResponseKey.androidNeedsPermission, [:]))
            return true
        }
        if !response.ok {
            speak(renderer.render(ResponseKey.androidCommandFailed,
                                  ["error": response.message ?? "Unknown error"]))
            return true
        }
        return false
    }

    /// Call a contact by name. If Android returns `needs_clarification` with
    /// multiple candidates, trigger a `.choice` follow-up.
    private func executeCallContact(name: String) async {
        guard requirePhoneOnline() else { return }
        guard !name.isEmpty else {
            speak("Who should I call?"); return
        }
        speak(renderer.render(ResponseKey.androidCalling, ["name": name]))
        let payload = AndroidCommandPayload(contact: name)
        let response = await androidBridge?.sendToAndroid(
            command: "call_contact", payload: payload,
            transcript: state.lastFinalTranscript, sessionId: sessionId)

        guard let response else { return }

        if response.status == AndroidResponseStatus.needsClarification,
           let contacts = response.payload?.contacts, contacts.count > 1 {
            // Offer disambiguation choices
            let choices = contacts.map { $0.name }
            let options = choices.prefix(4).joined(separator: ", ")
            speak(renderer.render(ResponseKey.androidContactAmbiguous,
                                  ["name": name, "options": options]))
            activePendingContext = PendingConversationContext.choice(
                originalTranscript: "call \(name)",
                originalIntent: .callContact(name: name),
                question: "Which \(name) — \(options)?",
                choices: choices,
                onChoice: { chosen in .executeIntent(.callContact(name: chosen)) }
            )
        } else {
            handleAndroidError(response)
        }
    }

    /// Call back the most recent missed or incoming caller.
    /// Resolves context from `androidEventReceiver` — no disambiguation needed.
    private func executeCallBackLastCaller() async {
        // Prefer the missed caller; fall back to the last active caller.
        // context.snapshot fields are non-optional Strings, so guard emptiness explicitly.
        let caller: String? = androidEventReceiver?.latestMissedCallerName
                           ?? androidEventReceiver?.latestCallerName
                           ?? (context.snapshot.lastMissedCallerName.isEmpty ? nil : context.snapshot.lastMissedCallerName)
                           ?? (context.snapshot.lastCallerName.isEmpty ? nil : context.snapshot.lastCallerName)

        guard let name = caller else {
            speak(renderer.render(ResponseKey.androidNoCallerContext, [:]))
            return
        }
        speak(renderer.render(ResponseKey.androidCallBackConfirm, ["name": name]))
        await executeCallContact(name: name)
    }

    /// Reply to the most recent SMS or WhatsApp sender.
    /// If message is empty, prompts via `.freeform` follow-up.
    private func executeReplyToLastSender(message: String) async {
        // WhatsApp sender takes priority (most recent messaging action).
        // context.snapshot fields are non-optional Strings, so guard emptiness explicitly.
        let whatsAppSender: String? = androidEventReceiver?.latestWhatsAppSender
                                   ?? (context.snapshot.lastWhatsAppSender.isEmpty ? nil : context.snapshot.lastWhatsAppSender)
        let smsSender: String? = androidEventReceiver?.latestSMSSender
                              ?? (context.snapshot.lastSMSSender.isEmpty ? nil : context.snapshot.lastSMSSender)

        if let wa = whatsAppSender {
            if message.isEmpty {
                speak("What should I say to \(wa) on WhatsApp?")
                activePendingContext = PendingConversationContext.make(
                    originalTranscript: "reply to \(wa)",
                    originalIntent: .replyToLastSender(message: ""),
                    assistantQuestion: "What should I say to \(wa) on WhatsApp?",
                    responseType: .freeform,
                    onFreeform: .captureTranscript { msg in .sendWhatsApp(recipient: wa, message: msg) }
                )
            } else {
                await executeSendWhatsApp(recipient: wa, message: message)
            }
        } else if let sms = smsSender {
            if message.isEmpty {
                speak("What should I say to \(sms)?")
                activePendingContext = PendingConversationContext.make(
                    originalTranscript: "reply to \(sms)",
                    originalIntent: .replyToLastSender(message: ""),
                    assistantQuestion: "What should I say to \(sms)?",
                    responseType: .freeform,
                    onFreeform: .captureTranscript { msg in .sendSMS(recipient: sms, message: msg) }
                )
            } else {
                await executeSendSMS(recipient: sms, message: message)
            }
        } else {
            speak(renderer.render(ResponseKey.androidNoSenderContext, [:]))
        }
    }

    // MARK: - Phase-1 call control helpers

    /// Answer the ringing call on the Android phone.
    private func executeAnswerCall() async {
        guard requirePhoneOnline() else { return }
        speak(renderer.render(ResponseKey.androidAnswerCall, [:]))
        let response = await androidBridge?.sendToAndroid(
            command: AndroidCapability.answerCall,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        handleAndroidError(response)
    }

    /// Decline / reject the ringing call on the Android phone.
    private func executeDeclineCall() async {
        guard requirePhoneOnline() else { return }
        speak(renderer.render(ResponseKey.androidDeclineCall, [:]))
        let response = await androidBridge?.sendToAndroid(
            command: AndroidCapability.declineCall,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        handleAndroidError(response)
    }

    /// End (hang up) the active call on the Android phone.
    private func executeHangUpCall() async {
        guard requirePhoneOnline() else { return }
        speak(renderer.render(ResponseKey.androidHangUp, [:]))
        let response = await androidBridge?.sendToAndroid(
            command: AndroidCapability.endCall,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if response?.status == AndroidResponseStatus.noActiveCall {
            speak(renderer.render(ResponseKey.androidNoActiveCall, [:]))
        } else {
            handleAndroidError(response)
        }
    }

    /// Route the active Android call audio to speakerphone.
    private func executeSpeakerOn() async {
        guard requirePhoneOnline() else { return }
        speak(renderer.render(ResponseKey.androidSpeakerOn, [:]))
        let response = await androidBridge?.sendToAndroid(
            command: AndroidCapability.speakerphoneOn,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if response?.status == AndroidResponseStatus.noActiveCall {
            speak(renderer.render(ResponseKey.androidNoActiveCall, [:]))
        } else {
            handleAndroidError(response)
        }
    }

    /// Place a WhatsApp voice or video call via the Android phone.
    ///
    /// Mac side is purely a router — Android does the actual work:
    ///   1. resolve contact name → WhatsApp-capable contact
    ///   2. handle ambiguous matches (multiple contacts of the same name)
    ///   3. launch the deep link
    ///   4. report success / failure
    ///
    /// Status strings we honour from the Android response:
    ///   * `"calling"`               → success, speak "Calling X on WhatsApp"
    ///   * `"contact_not_found"`     → "I couldn't find X on WhatsApp"
    ///   * `"whatsapp_not_installed"`→ "WhatsApp isn't installed on your phone"
    ///   * `"needs_clarification"`   → existing handler asks the user which contact
    ///   * everything else           → generic Android-command-failed handler
    private func executeWhatsAppCall(contact: String, video: Bool) async {
        guard requirePhoneOnline() else { return }
        let cleanedName = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            speak("I didn't catch who you want to call on WhatsApp.")
            return
        }
        let command = video
            ? AndroidCapability.whatsAppVideoCall
            : AndroidCapability.whatsAppVoiceCall
        let speakingKey = video
            ? ResponseKey.whatsAppVideoCallStarting
            : ResponseKey.whatsAppVoiceCallStarting
        // Speak the optimistic acknowledgement before round-trip — same
        // pattern as `executeCall(contact:)` for regular telephony.
        speak(renderer.render(speakingKey, ["name": cleanedName]))

        let payload = AndroidCommandPayload(
            contact: cleanedName,
            callType: video ? "video" : "voice")
        let response = await androidBridge?.sendToAndroid(
            command: command,
            payload: payload,
            transcript: state.lastFinalTranscript,
            sessionId: sessionId)

        // Status-based branching.  `handleAndroidError` covers the
        // generic permission-required / failed / unauthorized paths;
        // WhatsApp-specific outcomes (contact not found, app missing)
        // get their own dedicated responses.
        switch response?.status {
        case .some("calling"), .some("started"), .some(AndroidResponseStatus.completed):
            // Optimistic speech already delivered.
            return
        case .some("contact_not_found"):
            speak(renderer.render(ResponseKey.whatsAppContactNotFound, ["name": cleanedName]))
        case .some("whatsapp_not_installed"), .some("app_not_installed"):
            speak(renderer.render(ResponseKey.whatsAppNotInstalled))
        default:
            handleAndroidError(response)
        }
    }

    /// Route the active Android call audio off speakerphone.
    private func executeSpeakerOff() async {
        guard requirePhoneOnline() else { return }
        speak(renderer.render(ResponseKey.androidSpeakerOff, [:]))
        let response = await androidBridge?.sendToAndroid(
            command: AndroidCapability.speakerphoneOff,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if response?.status == AndroidResponseStatus.noActiveCall {
            speak(renderer.render(ResponseKey.androidNoActiveCall, [:]))
        } else {
            handleAndroidError(response)
        }
    }

    /// Send an SMS. If message is empty, ask via a `.freeform` follow-up.
    private func executeSendSMS(recipient: String, message: String) async {
        guard requirePhoneOnline() else { return }
        guard !recipient.isEmpty else {
            speak("Who should I text?"); return
        }
        if message.isEmpty {
            speak("What should I say to \(recipient)?")
            activePendingContext = PendingConversationContext.make(
                originalTranscript: "text \(recipient)",
                originalIntent: .sendSMS(recipient: recipient, message: ""),
                assistantQuestion: "What should I say to \(recipient)?",
                responseType: .freeform,
                onFreeform: .captureTranscript { msg in .sendSMS(recipient: recipient, message: msg) }
            )
            return
        }
        let payload = AndroidCommandPayload(recipient: recipient, message: message)
        let response = await androidBridge?.sendToAndroid(
            command: "send_sms", payload: payload,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if response?.ok == true {
            speak(renderer.render(ResponseKey.androidMessageSent, ["name": recipient]))
        } else {
            handleAndroidError(response)
        }
    }

    /// Send a WhatsApp message. If message is empty, ask via a `.freeform` follow-up.
    private func executeSendWhatsApp(recipient: String, message: String) async {
        guard requirePhoneOnline() else { return }
        guard !recipient.isEmpty else {
            speak("Who should I WhatsApp?"); return
        }
        if message.isEmpty {
            speak("What should I say to \(recipient) on WhatsApp?")
            activePendingContext = PendingConversationContext.make(
                originalTranscript: "whatsapp \(recipient)",
                originalIntent: .sendWhatsApp(recipient: recipient, message: ""),
                assistantQuestion: "What should I say to \(recipient) on WhatsApp?",
                responseType: .freeform,
                onFreeform: .captureTranscript { msg in .sendWhatsApp(recipient: recipient, message: msg) }
            )
            return
        }
        let payload = AndroidCommandPayload(recipient: recipient, message: message)
        let response = await androidBridge?.sendToAndroid(
            command: "send_whatsapp", payload: payload,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if response?.ok == true {
            speak(renderer.render(ResponseKey.androidMessageSent, ["name": recipient]))
        } else {
            handleAndroidError(response)
        }
    }

    /// Search contacts. Speaks result or offers choices for a follow-up action.
    private func executeFindContact(query: String) async {
        guard requirePhoneOnline() else { return }
        guard !query.isEmpty else {
            speak("Who are you looking for?"); return
        }
        let payload = AndroidCommandPayload(query: query)
        let response = await androidBridge?.sendToAndroid(
            command: "find_contact", payload: payload,
            transcript: state.lastFinalTranscript, sessionId: sessionId)
        if handleAndroidError(response) { return }
        if let contacts = response?.payload?.contacts, !contacts.isEmpty {
            if contacts.count == 1 {
                speak(renderer.render(ResponseKey.androidContactFound, ["name": contacts[0].name]))
            } else {
                // Multiple results — offer disambiguation for a follow-up call/message
                let choices = contacts.prefix(4).map { $0.name }
                let names = choices.joined(separator: ", ")
                speak(renderer.render(ResponseKey.androidContactAmbiguous,
                                      ["name": query, "options": names]))
                activePendingContext = PendingConversationContext.choice(
                    originalTranscript: "find contact \(query)",
                    originalIntent: .findContact(query: query),
                    question: "Which \(query) — \(names)?",
                    choices: Array(choices),
                    onChoice: { chosen in .executeIntent(.callContact(name: chosen)) }
                )
            }
        } else {
            speak("No contacts found for \(query).")
        }
    }

    // MARK: - Voice learning

    /// Recognized spoken patterns that indicate voice learning intent:
    ///   "when i say X do Y"
    ///   "when i say X show Y"
    ///   "when i say X open Y"
    ///   "if i say X do Y"
    ///   "teach jarvis X means Y"  (future-extensible)
    private struct VoiceLearningCapture {
        let triggerPhrase: String   // what the user wants to say
        let commandHint: String     // what they want it to do (raw)
    }

    private func detectVoiceLearning(normalized: String) -> VoiceLearningCapture? {
        // Pattern: "when i say <X> (do|show|open|play|start) <Y>"
        //          "if i say <X> (do|show|open|play|start) <Y>"
        let patterns: [String] = [
            #"^(?:when|if) i say (.+?) (?:do|show|open|play|start|run) (.+)$"#,
            #"^teach (?:jarvis|you) (.+?) means (.+)$"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: .caseInsensitive)
            else { continue }
            let ns = normalized as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: normalized, range: range),
               m.numberOfRanges >= 3 {
                let g1 = ns.substring(with: m.range(at: 1))
                let g2 = ns.substring(with: m.range(at: 2))
                return VoiceLearningCapture(triggerPhrase: g1, commandHint: g2)
            }
        }
        return nil
    }

    private func handleVoiceLearning(_ capture: VoiceLearningCapture,
                                     rawText: String) {
        // Try to find a command matching the hint text
        let hintNorm = TranscriptNormalizer.normalize(capture.commandHint)
        if let match = phraseMatcher.match(
            normalizedInput: hintNorm,
            definitions: phraseStore.definitions),
           let _ = IntentMapping.intent(for: match.commandId)
        {
            // Add the trigger phrase to that command
            let added = phraseStore.addPhrase(
                capture.triggerPhrase,
                to: match.commandId,
                matchType: .exact)
            if added {
                speak(renderer.render(ResponseKey.teachSuccess,
                                      ["phrase": capture.triggerPhrase,
                                       "action": match.displayName.lowercased()]))
            } else {
                speak(renderer.render(ResponseKey.teachFailed))
            }
        } else {
            // Resolve via existing IntentRouter to find the command ID
            let resolvedIntent = router.route(hintNorm)
            if let cmdId = IntentMapping.commandId(for: resolvedIntent) {
                let added = phraseStore.addPhrase(
                    capture.triggerPhrase,
                    to: cmdId,
                    matchType: .exact)
                if added {
                    speak(renderer.render(ResponseKey.teachCommandAdded, ["phrase": capture.triggerPhrase]))
                } else {
                    speak(renderer.render(ResponseKey.teachCommandFailed))
                }
            } else {
                speak(renderer.render(ResponseKey.teachCommandUnknown, ["hint": capture.commandHint]))
            }
        }
    }

    // MARK: - High-level verbs

    func speak(_ text: String, critical: Bool = false) {
        // Remote response capture: if a remote routing call is in-flight,
        // record the first response text so it can be routed back to the device.
        // This is checked BEFORE suppressNextSpeak so we always capture the text,
        // regardless of whether local TTS fires.
        if let capture = remoteResponseCapture {
            capture(text)
            remoteResponseCapture = nil
        }

        // Silent action suppression: dual-track CHAT_PLUS_TOOL silences the
        // entire command leg — no TTS, no chat message, no memory entry.
        // Must be checked first so the command leaves no visible trace.
        if suppressNextSpeak {
            suppressNextSpeak = false
            return
        }
        lastSpeakCalledAt = Date()   // synchronous sentinel — post-loop reads this
        let preprocessed = speechPreprocessor.process(text)
        let finalText = applyAddress(to: preprocessed)
        state.lastSpoken = finalText
        state.sessionLastSpoken = finalText
        state.lastBargeInReason = nil
        context.recordAction("speak: \(finalText.prefix(60))")
        conversations?.saveAssistantTurn(finalText)
        appendChatMessage(ChatMessage(role: .assistant, text: finalText))
        rollingMemory.addAssistantTurn(finalText)
        ExecutionTracer.shared.addStep("tts_started", detail: String(finalText.prefix(60)), runtimeID: "audio")
        SystemBus.shared.publish(TTSStartedEvent(text: finalText,
                                                  correlationID: ExecutionTracer.shared.activeCorrelationID))
        // Silent mode: suppress TTS unless caller marks as critical
        guard !state.operatingMode.suppressesTTS || critical else { return }
        tts.speak(finalText)
    }

    /// Applies address style from personality user_preferences.md.
    /// Appends ", sir" or ", {name}" before terminal punctuation.
    private func applyAddress(to text: String) -> String {
        let style = personality.addressStyle.lowercased()
        guard style != "none", !text.isEmpty else { return text }

        let address: String
        switch style {
        case "sir":  address = "sir"
        case "name":
            let name = personality.preferredName
            guard !name.isEmpty else { return text }
            address = name
        default:     return text
        }

        // Don't add address to questions or very short acks that already feel complete
        guard !text.hasSuffix("?") else { return text }
        // Don't double-add
        guard !text.lowercased().hasSuffix(address) else { return text }

        // Append before terminal punctuation
        let terminals: [Character] = [".", "!", "…"]
        if let last = text.last, terminals.contains(last) {
            return String(text.dropLast()) + ", \(address)\(last)"
        }
        return text + ", \(address)."
    }

    /// Called after personality files change — syncs derived settings.
    func syncPersonality() {
        playbook.setStyle(personality.responseStyle)
        let style = personality.responseStyle.rawValue
        let addr = personality.addressStyle
        Log.app.info("personality synced: style=\(style) address=\(addr)")
    }

    /// Maps operating mode → response style and persists the mode.
    func syncOperatingMode() {
        let style: ResponseStyle
        switch state.operatingMode {
        case .normal:   style = personality.responseStyle
        case .concise:  style = .minimal
        case .silent:   style = .minimal
        case .ambient:  style = .consistent
        }
        playbook.setStyle(style)
        context.setOperatingMode(state.operatingMode)
        prefs.update { $0.operatingModeRaw = state.operatingMode.rawValue }
        let modeStr = state.operatingMode.rawValue
        Log.app.info("operating mode: \(modeStr)")
    }

    /// Reads llmProviderModeRaw from prefs and applies it to the router.
    func syncLLMMode() {
        llmRouter.mode = LLMProviderMode(rawValue: prefs.current.llmProviderModeRaw) ?? .auto
    }

    /// Push user/assistant identity from prefs into the context snapshot so
    /// the LLM fallback always has accurate identity data.
    func syncIdentity() {
        context.setIdentity(
            userName: prefs.current.userName ?? "",
            assistantName: prefs.current.assistantName
        )
    }

    /// Dispatch a `MacSystemController.AppOpenResult` to spoken feedback.
    private func handleAppOpenResult(_ result: MacSystemController.AppOpenResult, query: String) {
        switch result {
        case .opened(let name):
            speak(renderer.render(ResponseKey.appOpened, ["app": name]))
        case .notFound(let name):
            speak(renderer.render(ResponseKey.appNotFound, ["app": name]))
        case .clarificationNeeded(let apps):
            let names = apps.map(\.name).joined(separator: ", ")
            speak(renderer.render(ResponseKey.appClarify, ["apps": names]))
        case .permissionRequired:
            speak(renderer.render(ResponseKey.appPermissionRequired))
        case .error(let msg):
            state.log("system", .warn, "app_open_error query=\(query) err=\(msg)")
            speak(renderer.render(ResponseKey.appNotFound, ["app": query]))
        }
    }

    /// Returns true when the user's query looks open-ended enough that
    /// speaking an acknowledgement before the LLM round-trip is worthwhile.
    /// Short commands ("open Safari") don't need one; longer questions do.
    private func shouldAcknowledgeLLMQuery(_ text: String) -> Bool {
        let questionStarters = ["what", "how", "why", "when", "where", "who",
                                "tell me", "explain", "can you", "could you",
                                "describe", "summarize", "summarise"]
        let wordCount = text.split(separator: " ").count
        return wordCount >= 5 || questionStarters.contains(where: { text.hasPrefix($0) })
    }

    // MARK: - Active-context pronoun resolution

    /// Outcome of resolving "open it" / "call him back" / "the second one"
    /// against `ActiveContextRegistry`.  Both fields optional so the caller
    /// can build prompts ("Should I open Mike's email?") that don't yet
    /// have an intent.
    struct ActiveContextResolution {
        let label: String
        let spokenReply: String?
        let intent: Intent?
    }

    /// Try to resolve a referring utterance ("open the second one", "call
    /// him back", "summarise that", "reply saying yes") against the most
    /// recent items in `ActiveContextRegistry`.
    ///
    /// Returns nil when no item matches; the conversational layer then
    /// falls through to the classified LLM pipeline.
    private func resolveRegistryReference(_ normalized: String) -> ActiveContextResolution? {
        let n = normalized.lowercased()

        // ── Named-feature bypass ──────────────────────────────────────────────
        // "show camera", "open news", "show calendar" etc. name specific Jarvis
        // features — they must fall through to the phrase-store / parsed NLP /
        // substring routing pipeline, NOT be swallowed here as pronoun references.
        // Only true contextual pronouns ("show that", "open it") or ordinals
        // ("open the second one") should ever reach the registry resolver.
        let namedFeatureKeywords: Set<String> = [
            "camera", "cameras", "news", "calendar", "tasks", "task",
            "home", "settings", "shopify", "github", "obsidian", "memory",
            "chat", "timeline", "notifications", "notification",
            "ambient", "context", "weather", "spotify", "music",
            "timer", "timers", "stopwatch", "diagnostics",
            "overlay", "overlays", "lights", "thermostat",
            "blinds", "covers", "notes", "reminders", "orders"
        ]
        for pfx in ["show ", "open "] {
            if n.hasPrefix(pfx) {
                let words     = String(n.dropFirst(pfx.count)).components(separatedBy: " ")
                let firstWord = words.first ?? ""
                let lastWord  = words.last  ?? ""
                // Check first AND last word — "show front door camera" has firstWord="front"
                // (not a keyword) but lastWord="camera" (is a keyword), so bypass correctly.
                if namedFeatureKeywords.contains(firstWord) || namedFeatureKeywords.contains(lastWord) {
                    let matched = namedFeatureKeywords.contains(firstWord) ? firstWord : lastWord
                    Log.app.debug("[resolveRegistryRef] bypassing '\(normalized)' — named feature '\(matched)' falls through to main pipeline")
                    return nil
                }
            }
        }

        // Extract the verb the user intends: open / summarise / dismiss /
        // call / reply.  Each maps to a different Intent factory below.
        enum Verb { case open, summarise, dismiss, call, replyYes, replyNo, describe }
        let verb: Verb? = {
            if n.hasPrefix("open ")     || n == "open it"       || n == "open that" { return .open }
            if n.hasPrefix("show ")     || n == "show me"       || n == "show that" { return .open }
            if n.hasPrefix("summar")                                                { return .summarise }
            if n.hasPrefix("dismiss")                                               { return .dismiss }
            if n.hasPrefix("call ")     || n.contains(" call him") || n.contains(" call her")
               || n.contains("call them back") || n.contains("call him back")
               || n.contains("call her back")                                       { return .call }
            if (n.contains("reply") || n.contains("respond"))
               && (n.contains("yes") || n.contains("ok") || n.contains("agree"))    { return .replyYes }
            if (n.contains("reply") || n.contains("respond"))
               && (n.contains("no") || n.contains("decline"))                       { return .replyNo }
            if n.contains("colour") || n.contains("color")
                || n.contains("what is it") || n.contains("what's it")              { return .describe }
            return nil
        }()

        // Ordinal extraction: "the second one", "open the third"
        let ordinal: Int? = {
            for (i, word) in ["first","second","third","fourth","fifth"].enumerated() {
                if n.contains(word) { return i + 1 }
            }
            return nil
        }()

        // Pick the pronoun the user used; default to "it" if none.
        let pronoun: String = {
            for p in ["him", "her", "they", "them", "those", "these"] {
                if n.contains(" \(p) ") || n.hasSuffix(" \(p)") { return p }
            }
            return "it"
        }()

        guard let item = activeContext.resolve(pronoun: pronoun, ordinal: ordinal) else {
            return nil
        }

        Log.app.debug("[resolveRegistryRef] resolved '\(normalized)' → item='\(item.title)' source=\(item.source.rawValue) verb=\(String(describing: verb))")

        // Verb mapping — keep simple, only return non-nil for cases the
        // existing Intent enum supports cleanly.
        switch verb {
        case .open:
            // Prefer item.openableURL when present — the `openURL` intent
            // accepts a URL and `NSWorkspace.open(_:)` handles both file://
            // and https schemes uniformly.
            if let openable = item.openableURL,
               !openable.isEmpty,
               let url = URL(string: openable) {
                return .init(label: "open_url",
                             spokenReply: nil,
                             intent: .openURL(url))
            }
            return .init(label: "open_default",
                         spokenReply: "I'm not sure how to open \(item.title) — could you be more specific?",
                         intent: nil)

        case .summarise:
            return .init(label: "summarise",
                         spokenReply: "Here's \(item.title): \(item.summary)",
                         intent: nil)

        case .dismiss:
            return .init(label: "dismiss",
                         spokenReply: nil,
                         intent: .dismissLatestAlert)

        case .call:
            // Specific to Android-call context items — they carry the
            // caller's name as the title and a contact reference via
            // `externalIdentifier` when known.
            if item.source == .androidCall {
                let contact = item.externalIdentifier ?? item.title
                return .init(label: "call_back",
                             spokenReply: "Calling \(item.title).",
                             intent: .callContact(name: contact))
            }
            return nil  // call only makes sense for call context

        case .replyYes:
            if item.source == .androidSMS || item.source == .androidWhatsApp {
                return .init(label: "reply_yes",
                             spokenReply: "Replying yes to \(item.title).",
                             intent: replyIntentForContextItem(item, body: "Yes"))
            }
            if item.source == .email {
                return .init(label: "reply_yes_email_placeholder",
                             spokenReply: "Replying to email isn't wired up yet.",
                             intent: nil)
            }
            return nil

        case .replyNo:
            if item.source == .androidSMS || item.source == .androidWhatsApp {
                return .init(label: "reply_no",
                             spokenReply: "Replying no to \(item.title).",
                             intent: replyIntentForContextItem(item, body: "No"))
            }
            if item.source == .email {
                return .init(label: "reply_no_email_placeholder",
                             spokenReply: "Replying to email isn't wired up yet.",
                             intent: nil)
            }
            return nil

        case .describe:
            // "what colour is it" / "what is it" — answer from the
            // item's summary.  If the summary already contains a
            // descriptive phrase we use it directly; otherwise we hand
            // off to the LLM with the registry block as context.
            if !item.summary.isEmpty {
                return .init(label: "describe_from_ctx",
                             spokenReply: item.summary,
                             intent: nil)
            }
            return nil  // fall through to LLM

        case .none:
            return nil
        }
    }

    /// Build an "SMS / WhatsApp reply" intent for an active-context item.
    /// Email replies are not yet a first-class Intent — those resolutions
    /// speak a placeholder.  Once an `Intent.replyToEmail` exists, wire it
    /// in here.
    private func replyIntentForContextItem(_ item: ActiveContextItem,
                                            body: String) -> Intent? {
        let contactRef = item.externalIdentifier ?? item.title
        switch item.source {
        case .androidSMS:        return .sendSMS(recipient: contactRef, message: body)
        case .androidWhatsApp:   return .sendWhatsApp(recipient: contactRef, message: body)
        default:                 return nil
        }
    }

    // MARK: - Classified unknown routing

    /// Route an unmatched utterance based on `QuestionClassifier.Kind`.
    /// Returns true when the utterance was handled (TTS, intent, etc).
    /// False means the caller should let `unknown` fall through to the
    /// graceful "I'm not sure" path — but that path now uses a softer
    /// message and offers to retry.
    @discardableResult
    private func routeUnknownByClassification(
        kind: QuestionClassifier.Kind,
        rawText: String,
        normalized: String
    ) async -> Bool {
        switch kind {

        case .clarificationReply, .unsupportedCommand:
            // Both go to the existing intent-JSON LLM path — they're action-
            // shaped and we want a structured response that maps to an
            // intent (or a clarification question back to the user).
            return await tryLLMFallback(rawText: rawText, normalized: normalized)

        case .contextualFollowUp, .factualQuestion, .memoryQuestion,
             .webSearchQuestion, .generalChat:
            // Free-text LLM answer with active-context block + memory.
            return await tryLLMFreeTextAnswer(
                rawText: rawText,
                normalized: normalized,
                classifierKind: kind)
        }
    }

    /// Free-text LLM completion that answers a question conversationally,
    /// using `ActiveContextRegistry` + memory + Obsidian as context.  When
    /// the classifier said `.webSearchQuestion` we attempt a web search
    /// first; if no provider is configured we transparently fall back to
    /// pure LLM.  The model is told to answer in natural prose — no
    /// intent JSON — so this never produces "no action" replies.
    @discardableResult
    private func tryLLMFreeTextAnswer(
        rawText: String,
        normalized: String,
        classifierKind: QuestionClassifier.Kind
    ) async -> Bool {
        guard llmRouter.mode != .disabled else {
            // Even without LLM, try to answer from active context / memory.
            return await answerFromContextOnly(rawText: rawText)
        }
        if circuitBreaker.allCircuitsOpen {
            state.log("llm", .warn, "freetext_skipped all_circuits_open")
            return await answerFromContextOnly(rawText: rawText)
        }

        // Short acknowledgement for open-ended questions, same behaviour
        // as the intent-JSON path.
        if shouldAcknowledgeLLMQuery(normalized) {
            llmAckIndex = (llmAckIndex + 1) % llmAcknowledgements.count
            speak(llmAcknowledgements[llmAckIndex])
        }

        // Optional web-search hop for clearly current-info questions.
        var searchBlock: String? = nil
        if classifierKind == .webSearchQuestion,
           await webSearch.isAvailable(),
           let results = await webSearch.search(query: rawText, limit: 4),
           !results.isEmpty {
            searchBlock = renderWebSearchBlock(results)
            // Record the search results as an LLM-answer-ready context item
            // so a future "open the first source" follow-up works.
            activeContext.record(
                source: .webArticle,
                title: "Web search: \(rawText.prefix(40))",
                summary: results.answerDigest ?? results.results.first?.snippet ?? "",
                openableURL: results.results.first?.url,
                priority: 1)
        }

        // Compose context: ContextEngine snapshot + active-context registry
        // + memory hits + Obsidian + optional web-search block.
        var ctx = PromptBudgeter.trimContext(context.snapshot.summaryString())
        let registryBlock = activeContext.contextBlock(maxItems: 8, window: 600)
        if !registryBlock.isEmpty {
            ctx = ctx.isEmpty ? registryBlock : ctx + "\n\n" + registryBlock
        }
        if let svc = search {
            let memResults = await svc.hybridSearch(query: rawText, limit: 3)
            let memTexts = memResults.filter { $0.kind == .memory }.map { $0.text }
            if !memTexts.isEmpty {
                let block = "Relevant memories:\n" + memTexts.map { "- \($0)" }.joined(separator: "\n")
                ctx = ctx.isEmpty ? block : ctx + "\n\n" + block
            }
        }
        if prefs.current.obsidianLLMContextEnabled,
           let vault = await obsidianVault.contextForLLM(
               query: rawText,
               maxNotes: prefs.current.obsidianMaxContextNotes,
               maxCharsPerNote: 600) {
            ctx = ctx.isEmpty ? vault : ctx + "\n\n" + vault
        }
        if let searchBlock {
            ctx = ctx.isEmpty ? searchBlock : ctx + "\n\n" + searchBlock
        }

        // Free-text system prompt — distinct from the intent-classifier prompt.
        // The LLM answers in 1-3 spoken sentences, conversationally.
        let personality = contextBuilder.buildSystemPrompt(
            userName:      context.snapshot.userName.isEmpty ? nil : context.snapshot.userName,
            assistantName: context.snapshot.assistantName)
        let system = """
        \(personality.isEmpty ? "" : personality + "\n\n---\n\n")\
        You are Jarvis, a macOS voice assistant.  The user just asked a question \
        the deterministic command pipeline couldn't map to an action.  Answer \
        conversationally in 1–3 short sentences suitable for TTS.  Use the \
        "Active context" and "Relevant memories" blocks below to ground your \
        answer when they're useful; ignore them when they're not.  If you do \
        not know and there is no provided context to answer from, say so \
        plainly — do NOT make up facts.  Never output JSON; respond in \
        natural prose only.
        """

        let req = LLMRequest(
            systemPrompt:   system,
            userPrompt:     rawText,
            contextSummary: ctx.isEmpty ? nil : ctx,
            temperature:    0.4,
            maxTokens:      220,
            responseFormat: .text,
            timeoutSeconds: 10)

        latency.mark(.llmStart)
        let response: LLMResponse
        do {
            response = try await llmRouter.complete(req, circuitBreaker: circuitBreaker)
            latency.mark(.llmComplete)
            latency.measure(from: .llmStart, to: .llmComplete, recordAs: .llmComplete)
        } catch {
            state.llmLastError = error.localizedDescription
            state.log("llm", .warn, "freetext_failed: \(error.localizedDescription)")
            return await answerFromContextOnly(rawText: rawText)
        }

        state.llmProviderUsed = response.providerID
        state.llmModelUsed    = response.model
        state.llmLatencyMs    = response.latencyMs
        state.llmFallbackUsed = true
        state.llmLastError    = nil

        // Wire Gemini-specific diagnostics when Gemini answered.
        if response.providerID == "gemini" {
            state.geminiConfiguredModel  = llmRouter.gemini.configuredModel
            state.geminiResolvedModel    = llmRouter.gemini.resolvedModel ?? response.model
            state.geminiModelAvailable   = llmRouter.gemini.modelStatus == .available
            state.geminiLastListModelsAt = llmRouter.gemini.lastListModelsAt
            state.geminiLastFailure      = llmRouter.gemini.lastFailureReason ?? ""
        }

        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return await answerFromContextOnly(rawText: rawText)
        }
        speak(text)
        // Record the answer as its own active-context item so the user can
        // follow up on it ("tell me more about that", "save that").
        activeContext.record(
            source: .llmAnswer,
            title: "Previous answer",
            summary: String(text.prefix(200)),
            priority: 0,
            suggestedActions: [.describeMore])
        return true
    }

    /// Best-effort answer when the LLM is unavailable or has failed.
    /// Uses the most recent ActiveContextRegistry item's summary if any;
    /// otherwise speaks a soft "I'm not sure" — but specifically NOT the
    /// "I don't have an action for that yet" message, since the user
    /// asked a question, not a command.
    @discardableResult
    // MARK: - Tool + Reasoning pipeline

    /// Entry point for CHAT_PLUS_TOOL_PLUS_REASONING route.
    /// Runs the appropriate tool pipeline (camera, screenshot, diagnostics, browser),
    /// injects the result into the LLM, and produces a conversational reply.
    private func handleToolPlusReasoning(
        transcript: String,
        normalized: String,
        toolHint: String
    ) async {
        state.phase = .thinking
        rollingMemory.addUserTurn(transcript, intent: nil, route: .chatPlusToolPlusReasoning)

        state.log("tool_reasoning", .info,
            "hint=\(toolHint) query=\"\(transcript.prefix(60))\"")

        switch toolHint {
        case "camera":
            await VisionActionPipeline.shared.run(query: transcript)

        case "screenshot":
            await ScreenshotActionPipeline.shared.run(query: transcript)

        case "diagnostics":
            // Run diagnostics summary through the reasoning pipeline
            let diagSummary = buildDiagnosticsSummary()
            let stages = [ToolExecutionGraph.Stage(kind: .diagnosticsAnalysis, timeoutSeconds: 2.0)]
            let result = await ToolExecutionGraph.shared.execute(stages: stages, query: transcript) { _ in diagSummary }
            await PostToolContextInjection.shared.inject(result: result)

        default:
            // Unknown tool hint — fall back to camera pipeline as the primary visual tool
            await VisionActionPipeline.shared.run(query: transcript)
        }
    }

    /// Uses the LLM to reason over a tool result and speak a conversational answer.
    /// The toolContext block is injected as a one-shot system context so the LLM
    /// can reference it while generating the response.
    private func speakWithToolContext(query: String, context: String) async {
        guard let handler = llmFallbackHandler else {
            speak("I analyzed that but couldn't generate a response.")
            return
        }
        handler.temporaryAdditionalContext = context
        _ = await tryLLMFallback(rawText: query, normalized: query.lowercased())
    }

    /// Builds a brief diagnostics summary string for the reasoning pipeline.
    private func buildDiagnosticsSummary() -> String {
        var parts: [String] = []
        parts.append("Phase: \(state.phase)")
        parts.append("STT: \(state.isListening ? "active" : "idle")")
        parts.append("TTS: \(state.isSpeaking ? "speaking" : "idle")")
        parts.append("Recent failures: \(RuntimeHealthMonitor.shared.recentFailureSummary)")
        parts.append("Latency: \(LatencyBudgetSystem.shared.summaryReport())")
        return parts.joined(separator: "; ")
    }

    // MARK: - Conversational Jarvis (Sprint K)

    /// Entry point for non-command turns: PROJECT_REFLECTION, GENERAL_CHAT,
    /// KNOWLEDGE_QUERY, MEMORY_UPDATE. Called from handleTranscript when the
    /// ConversationRouter short-circuits with confidence ≥ 0.70.
    private func handleConversationalTurn(
        _ routeResult: ConversationRouteResult,
        transcript: String,
        normalized: String
    ) async {
        state.phase = .thinking
        // User message was already appended to chatMessages at the top of
        // handleTranscript — do NOT append again here.

        let sessionId = activeSession?.shortID ?? "conv"
        let route = routeResult.route

        // 0. Inject rolling dialogue context into turn
        rollingMemory.addUserTurn(transcript, intent: nil, route: route)

        // 0.5. Self-query intercept: answer questions about Jarvis itself from grounded sources
        if prefs.current.selfKnowledgeEnabled {
            let selfSvc = JarvisSelfQueryService.shared
            if selfSvc.isAboutSelf(normalized) {
                if let result = await selfSvc.query(
                    userQuery: transcript,
                    activeTopic: rollingMemory.activeTopic
                ), !result.isEmpty, result.confidence >= 0.65 {
                    speak(result.suggestedAnswer)
                    return
                }
            }
        }

        // 1. Retrieve project knowledge (only for project/knowledge routes)
        let knowledge: KnowledgeContext
        if prefs.current.projectKnowledgeEnabled &&
            (route == .projectReflection || route == .knowledgeQuery) {
            knowledge = await projectKnowledge.retrieve(for: transcript, route: route)
            if prefs.current.conversationalDiagnosticsEnabled {
                state.log("conv_router", .info,
                    "knowledge_retrieved sources=\(knowledge.sources.joined(separator: ",")) summary=\"\(knowledge.summary)\"")
            }
        } else {
            knowledge = .empty
        }

        // 2. Acknowledgement for knowledge-heavy queries (feels more responsive)
        if route == .projectReflection && !knowledge.isEmpty {
            let acks = ["Let me check the project context.", "Looking at that now.", "Checking the roadmap."]
            if shouldAcknowledgeLLMQuery(normalized) {
                speak(acks[abs(normalized.hashValue) % acks.count])
            }
        }

        // 3. Compose the answer
        // Build history from the full chatMessages buffer (includes responses
        // from the command pipeline such as weather failures) so follow-up
        // questions like "why not?" have the prior exchange as context.
        // Drop the last entry — that is the current user transcript, already
        // passed as the `transcript` parameter.
        let chatHistoryLines = state.chatMessages
            .dropLast()
            .suffix(6)
            .map { msg -> String in
                let role = msg.role == .user ? "User" : "Jarvis"
                return "\(role): \(msg.text)"
            }
        let chatHistory = chatHistoryLines.joined(separator: "\n")
        let recentHistory = chatHistory.isEmpty
            ? ConversationMemoryStore.shared.formattedHistory(limit: 3)
            : chatHistory

        // Emotional tone hint: guides the LLM toward a register that fits the user's mood.
        let toneHint: String? = {
            switch rollingMemory.emotionalTone {
            case .frustrated: return "User sounds frustrated. Be brief, direct, skip all preamble."
            case .stressed:   return "User sounds stressed. Be calm, concise, and reassuring."
            case .tired:      return "User sounds tired. Keep the response short and simple."
            default:          return nil
            }
        }()

        let answer: String?

        if route == .memoryUpdate {
            // Memory saves don't need an LLM — confirm and save
            answer = handleMemoryUpdateTurn(transcript: transcript, normalized: normalized)
        } else {
            answer = await answerComposer.compose(
                transcript: transcript,
                route: route,
                knowledgeContext: knowledge,
                recentChatHistory: recentHistory.isEmpty ? nil : recentHistory,
                userName: prefs.current.userName,
                toneHint: toneHint
            )
        }

        let responseText = answer ?? "I'm not sure about that one."
        speak(responseText)
        appendChatMessage(ChatMessage(role: .assistant, text: responseText))
        conversations?.saveAssistantTurn(responseText)

        // 4. Log turn to ConversationMemoryStore
        let turn = ConversationTurn(
            sessionId: sessionId,
            timestamp: Date(),
            transcript: transcript,
            route: route,
            response: responseText,
            memoryCandidatesExtracted: 0
        )
        ConversationMemoryStore.shared.logTurn(turn)

        // 5. Async memory extraction (doesn't block the response)
        if !memoryLoggingPaused {
            Task {
                let candidates = await memoryExtractor.extract(
                    transcript: transcript,
                    route: route,
                    response: responseText
                )
                let autoSave = prefs.current.conversationalMemoryAutoSave
                for candidate in candidates {
                    let shouldSave = autoSave == "auto_all" ||
                        (autoSave == "auto_project" && (candidate.tier == .projectMemory || candidate.tier == .longTermUserPreference))
                    if shouldSave {
                        ConversationMemoryStore.shared.saveMemory(candidate)
                        // Also persist to MemoryStore for LLM context
                        if candidate.confidence >= 0.75 {
                            memories?.remember(candidate.summary, tags: candidate.tags.joined(separator: ","))
                        }
                        // Export to Obsidian daily note
                        if prefs.current.conversationalDailyNotesEnabled {
                            await obsidianExporter.exportMemoryCandidate(candidate, vaultPath: prefs.current.obsidianVaultPath)
                        }
                        // Commit to Brain long-term memory
                        var brainCandidate          = candidate
                        brainCandidate.source       = .memoryExtractor
                        brainCandidate.importance   = brainImportance(for: candidate.type)
                        let brainScore = brainCandidate.confidence * brainCandidate.importance
                        if brainScore >= BrainMemoryStore.autoCommitThreshold {
                            let committed = await BrainMemoryStore.shared.commit(brainCandidate)
                            if committed { EpisodeStore.shared.linkMemory(brainCandidate.id.uuidString) }
                        }
                    }
                }
                // Export conversation summary to Obsidian
                if prefs.current.conversationalDailyNotesEnabled,
                   route == .projectReflection || route == .knowledgeQuery {
                    let summary = "\(transcript.prefix(100)) → \(responseText.prefix(120))"
                    await obsidianExporter.export(content: summary, section: .conversations, vaultPath: prefs.current.obsidianVaultPath)
                }
            }
        }

        // 6. Update proactivity / execution trace
        ExecutionTracer.shared.addStep("conv_turn", detail: "\(route.rawValue) → \(responseText.prefix(40))", runtimeID: "conversation")
        state.phase = .idle
    }

    /// Maps MemoryCandidateType to an importance score for Brain commit scoring.
    private func brainImportance(for type: MemoryCandidateType) -> Double {
        switch type {
        case .roadmapChange:              return 0.85
        case .projectDecision:            return 0.80
        case .projectProgress, .personalFact: return 0.75
        case .userPreference:             return 0.70
        case .bugReport:                  return 0.65
        case .idea:                       return 0.60
        default:                          return 0.30
        }
    }

    /// Handle MEMORY_UPDATE turns — save last context or explicit text.
    private func handleMemoryUpdateTurn(transcript: String, normalized: String) -> String {
        let t = normalized.lowercased()

        // "save that" / "log that" — save last spoken response
        let saveThat = ["save that", "log that", "save this", "log this",
                        "mark that as done", "mark that complete", "log that as done"]
        if saveThat.contains(where: { t.contains($0) }) {
            let lastResponse = state.lastSpoken
            if !lastResponse.isEmpty {
                let candidate = MemoryCandidate(
                    type: .projectProgress,
                    tier: .projectMemory,
                    title: "Logged: \(lastResponse.prefix(60))",
                    summary: lastResponse,
                    rawText: transcript,
                    confidence: 0.85,
                    tags: ["project", "progress", "manual"],
                    createdAt: Date()
                )
                ConversationMemoryStore.shared.saveMemory(candidate)
                memories?.remember(lastResponse, tags: "project,progress,manual")
                if prefs.current.conversationalDailyNotesEnabled {
                    Task {
                        await obsidianExporter.export(
                            content: lastResponse,
                            section: .projectProgress,
                            vaultPath: prefs.current.obsidianVaultPath
                        )
                    }
                }
                return renderer.render(ResponseKey.progressSaved)
            }
            return "Nothing to save yet — try saying something about the project first."
        }

        // "add to roadmap" / "save to roadmap"
        let toRoadmap = ["add to roadmap", "save to roadmap", "add that to the roadmap"]
        if toRoadmap.contains(where: { t.contains($0) }) {
            let lastResponse = state.lastSpoken
            if !lastResponse.isEmpty {
                memories?.remember(lastResponse, tags: "roadmap,manual")
                if prefs.current.conversationalDailyNotesEnabled {
                    Task {
                        await obsidianExporter.export(
                            content: lastResponse,
                            section: .projectProgress,
                            vaultPath: prefs.current.obsidianVaultPath
                        )
                    }
                }
                return "Added to the roadmap."
            }
        }

        // "remember that X" — extract the X
        if let range = t.range(of: "remember that ") {
            let content = String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !content.isEmpty {
                memories?.remember(content, tags: "manual,user-stated")
                ConversationMemoryStore.shared.saveMemory(MemoryCandidate(
                    type: .projectDecision,
                    tier: .projectMemory,
                    title: String(content.prefix(60)),
                    summary: content,
                    rawText: transcript,
                    confidence: 0.90,
                    tags: ["manual"],
                    createdAt: Date()
                ))
                return renderer.render(ResponseKey.memorySaved)
            }
        }

        return renderer.render(ResponseKey.memorySaved)
    }

    private func answerFromContextOnly(rawText: String) async -> Bool {
        if let recent = activeContext.mostRecent, !recent.summary.isEmpty {
            speak(recent.summary)
            return true
        }
        speak("I'm not sure about that. I can try again if you rephrase, or I can search the web if you've set up a search provider.")
        return true
    }

    /// Convert `WebSearchResults` into a short prompt-friendly block.
    private func renderWebSearchBlock(_ results: WebSearchResults) -> String {
        var lines: [String] = ["Web search results for: \(results.query)"]
        if let d = results.answerDigest, !d.isEmpty {
            lines.append("Answer card: \(d.prefix(280))")
        }
        for (i, r) in results.results.prefix(4).enumerated() {
            lines.append("\(i + 1). \(r.title) — \(r.snippet.prefix(160))  [\(r.url)]")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - LLM fallback

    /// Delegates to LLMFallbackHandler. See LLMFallbackHandler.swift for the
    /// full implementation — extracted in Sprint N decomposition.
    @discardableResult
    private func tryLLMFallback(rawText: String, normalized: String) async -> Bool {
        guard let handler = llmFallbackHandler else { return false }
        return await handler.handle(rawText: rawText, normalized: normalized)
    }

    // MARK: - LLM-enhanced news summary

    /// Summarise headlines with the LLM when available, falling back to the
    /// deterministic `NewsSummariser` when the LLM is disabled or unreachable.
    private func summariseNewsWithLLM(_ articles: [NewsArticle]) async -> String {
        guard llmRouter.mode != .disabled else {
            return NewsSummariser.digestSummary(articles: articles)
        }
        let headings = articles.prefix(6).enumerated()
            .map { "\($0.offset + 1). \($0.element.title)" }
            .joined(separator: "\n")
        let req = LLMRequest(
            systemPrompt: """
            You are Jarvis, a macOS voice assistant. Summarise these news headlines
            in 2–3 natural spoken sentences. No lists, no bullet points, under 60 words.
            """,
            userPrompt:     "Headlines:\n\(headings)",
            contextSummary: nil,
            temperature:    0.4,
            maxTokens:      150,
            responseFormat: .text,
            timeoutSeconds: 20
        )
        do {
            let response = try await llmRouter.complete(req)
            state.llmProviderUsed = response.providerID
            state.llmModelUsed    = response.model
            state.llmLatencyMs    = response.latencyMs
            state.llmLastError    = nil
            return response.text
        } catch {
            state.llmLastError = error.localizedDescription
            return NewsSummariser.digestSummary(articles: articles)
        }
    }


    /// Called each second from latencyPublishTask — re-evaluates attention,
    /// syncs context snapshot, drains notification queue when appropriate.
    private func tickAttentionAndContext() {
        let newAttention = attention.evaluateFromState(
            presenceDetected: state.faceCount > 0,
            isConversational: state.phase == .conversationalListening,
            isSpeaking: state.isSpeaking,
            isListening: state.isListening,
            activeAppName: state.activeApp,
            overlayOpen: !overlayManager.overlays.isEmpty,
            screenWatching: state.screenWatchActive,
            cameraWatching: state.cameraWatchActive
        )
        if newAttention != state.attentionState {
            state.attentionState = newAttention
            context.setAttention(newAttention)
            activityTimeline.record(kind: .attentionChange,
                                    title: newAttention.displayName,
                                    appName: state.activeApp)
        }

        // Sync overlay list into context
        let overlayNames = overlayManager.overlays.map { $0.kind.rawValue }
        context.setOpenOverlays(overlayNames)

        // Top entities into context
        let topEntities = entityGraph.topNodes(limit: 5).map { $0.label }
        context.setTopEntities(topEntities)

        // Recent activity into context
        let recentTitles = activityTimeline.recent(limit: 5).map { $0.title }
        context.setRecentActivity(recentTitles)

        // Pending notifications
        context.setPendingNotifications(notificationQueue.pending.count)
        state.pendingNotificationCount = notificationQueue.pending.count

        // Listening session diagnostics (drives Debug HUD live)
        if let s = activeSession {
            state.listeningMinRemainingMs = Int(s.minListenRemainingSeconds * 1000)
            state.listeningRestartCount = s.restartCount
            state.listeningSawAudioBuffer = s.hasReceivedAudioBuffer
            state.listeningSessionShortID = s.shortID
        } else {
            state.listeningMinRemainingMs = 0
            state.listeningRestartCount = 0
            state.listeningSawAudioBuffer = false
            state.listeningSessionShortID = ""
        }

        // Watchdog: ensure wake-word stays alive when it should.
        wakeWatchdogTick()

        // News headlines into context (cheap — in-memory)
        let headlines = newsStore.articles.prefix(3).map { $0.title }
        if !headlines.isEmpty {
            context.setNewsHeadlines(Array(headlines))
        }

        // Drain queue when attention is permissive
        notificationQueue.drainIfAppropriate(attention: newAttention)
    }

    // MARK: - Chat support

    private func appendChatMessage(_ message: ChatMessage) {
        let cap = 300
        if state.chatMessages.count >= cap {
            state.chatMessages.removeFirst(state.chatMessages.count - cap + 1)
        }
        state.chatMessages.append(message)
    }

    private func loadChatHistory() async {
        guard state.chatMessages.isEmpty else { return }
        let recent = (await conversations?.recent(limit: 50)) ?? []
        // recent() returns newest-first; reverse for chronological display
        let historical: [ChatMessage] = recent.reversed().compactMap { row in
            guard !row.text.isEmpty else { return nil }
            return ChatMessage(
                role: row.role == "user" ? .user : .assistant,
                text: row.text,
                timestamp: row.ts
            )
        }
        if state.chatMessages.isEmpty {
            state.chatMessages = historical
        }
    }

    /// Routes a typed message through the same pipeline as a voice command.
    func sendTypedMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.chatInputProcessing = true
        await handleTranscript(trimmed)
        state.chatInputProcessing = false
    }

    /// Open an overlay and record to activity timeline.
    func openOverlay(_ kind: OverlayKind) {
        overlayManager.open(kind)
        state.sessionLastOverlayKind = kind
        state.lastOverlayEvent = "opened:\(kind.rawValue)"
        activityTimeline.record(kind: .overlayOpened,
                                title: kind.title,
                                appName: state.activeApp)
        entityGraph.recordOverlayOpen(kind.rawValue,
                                      triggeredBy: state.lastIntent.map { "cmd:\(String(describing: $0).prefix(40))" })
    }

    // MARK: - News article / channel helpers

    /// Open a news article inside the in-app `.article` overlay. Falls
    /// back to the external browser when the article has no usable URL
    /// or the user has chosen browser-by-default behaviour.
    func openArticle(_ article: NewsArticle, forceExternal: Bool = false) {
        state.lastClickedArticleTitle = article.title
        state.lastClickedArticleURL = article.url
        guard let url = URL(string: article.url), !article.url.isEmpty else {
            state.log("news", .warn,
                "article_clicked title=\"\(article.title.prefix(60))\" — no URL")
            speak(renderer.render(ResponseKey.newsArticleNoLink))
            return
        }
        state.log("news", .info,
            "article_clicked title=\"\(article.title.prefix(60))\" url=\(url.absoluteString)")
        // Default: open in-app via the .article overlay. The flag is
        // wired for a future preference toggle.
        let openInApp = !forceExternal
        if openInApp {
            state.currentArticleURL = url
            state.currentArticleTitle = article.title
            state.currentArticleSource = article.sourceName
            openOverlay(.article)
            state.log("news", .info,
                "article_opened_in_app title=\"\(article.title.prefix(60))\"")
            newsStore.markRead(articleID: article.id)
        } else {
            actions.openURL(url)
            state.log("news", .info,
                "article_opened_in_browser title=\"\(article.title.prefix(60))\"")
            newsStore.markRead(articleID: article.id)
        }
    }

    /// Open the currently-focused article externally. Used by the
    /// "open in browser" voice command and the article overlay button.
    func openCurrentArticleInBrowser() {
        guard let url = state.currentArticleURL else {
            speak(renderer.render(ResponseKey.newsArticleNoFocus))
            return
        }
        actions.openURL(url)
        state.log("news", .info,
            "article_opened_in_browser url=\(url.absoluteString)")
    }

    /// Called when the news channel changes (voice or click). Surfaces
    /// the new channel name to AppState for diagnostics and toasts.
    func onNewsChannelChanged(_ channel: NewsChannel) {
        state.activeNewsChannelName = channel.name
        // Reset per-channel load status so the selector shows "loading"
        // for the new channel until the WKWebView reports back.
        state.newsChannelLoadStatus[channel.id] = "loading"
        state.newsChannelLastError.removeValue(forKey: channel.id)
        state.log("news", .info,
            "news_channel_selected id=\(channel.id) name=\(channel.name)")
        showToast(channel.name, icon: "dot.radiowaves.left.and.right")
    }

    // MARK: - Watch-news listening lifecycle

    /// Transition into media-playback mode.  Pauses active STT, leaves
    /// wake word armed, sets the diagnostic state.  Wake-word can still
    /// fire — the user can interrupt the video with "Jarvis, pause news".
    func enterMediaPlayback(channel: String) {
        // No-op if we're already playing this channel — re-entry would
        // bounce the listening pipeline unnecessarily on channel-switch.
        if case .playing(let cur) = state.mediaPlaybackState, cur == channel {
            return
        }
        state.log("media", .info, "media_playback_enter channel=\(channel)")
        state.mediaPlaybackState = .playing(channel: channel)
        // Pause STT but NOT the conversational arm — the session can
        // resume cleanly when the user closes the player.  We pass
        // permanent: false so the 10-minute armed window is preserved.
        endConversationalSession(permanent: false)
        JarvisTelemetry.shared.record(.ttsInterrupted, [
            "kind": "media_playback_start",
            "channel": channel,
        ])
    }

    /// Transition out of media-playback mode.  Restores normal listening.
    func exitMediaPlayback() {
        guard state.mediaPlaybackState != .inactive else { return }
        state.log("media", .info,
            "media_playback_exit was=\(state.mediaPlaybackState.displayLabel)")
        state.mediaPlaybackState = .inactive
        // If a conversational session was armed before the user said
        // "watch news", `endConversationalSession` left
        // `conversationalArmed` alone — the next user utterance after
        // wake word will start a fresh STT window via the normal flow.
    }

    /// Update the per-channel load status from `LiveNewsPlayerView`.
    /// Status strings: "loading", "playing", "blocked", "failed".
    func recordNewsChannelLoadStatus(channelId: String,
                                      status: String,
                                      error: String? = nil) {
        state.newsChannelLoadStatus[channelId] = status
        if let error = error {
            state.newsChannelLastError[channelId] = error
        } else if status == "playing" {
            state.newsChannelLastError.removeValue(forKey: channelId)
        }
        state.log("news", .info,
            "news_channel_load id=\(channelId) status=\(status) err=\(error ?? "—")")
    }

    func showToast(_ message: String, icon: String = "checkmark.circle.fill") {
        toastClearTask?.cancel()
        withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
            state.toastMessage = message
            state.toastIcon = icon
        }
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.32)) {
                self?.state.toastMessage = nil
            }
        }
    }

    func persistUIMode() {
        prefs.update { $0.uiModeRaw = state.uiMode.rawValue }
    }

    func persistStatusStrip() {
        prefs.update { $0.statusStripVisible = state.statusStripVisible }
    }

    func stopSpeaking() {
        // "Stop talking" silences TTS but does NOT end the conversational session —
        // the user can still speak follow-up commands. rewireSpeakingObserver will
        // fire the isSpeakingStream=false event and restart STT if session is armed.
        conversationalTimeoutTask?.cancel()
        tts.stop()
        // Explicitly re-arm STT if a conversational session is active, because
        // tts.stop() fires isSpeaking=false asynchronously via the stream and the
        // normal rewireSpeakingObserver path may have already passed by the time
        // TTS is forcibly cut. Belt-and-suspenders only — the observer handles it
        // in the normal case.
        if conversationalArmed,
           prefs.current.conversationalFollowUpEnabled,
           state.listeningEnabled {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms settle
                guard let self, !self.state.isListening else { return }
                self.startConversationalListening()
            }
        } else {
            // After stopping TTS, return to passive wake — not dead idle.
            returnToPassiveWake(reason: .userCancelled)
        }
    }

    func openApp(named name: String) async throws {
        try await actions.openApp(named: name)
        context.recordAction("openApp: \(name)")
    }

    /// Propagates a `VisionProviderResult` into AppState diagnostics and
    /// builds a `VisionContext` for LLM follow-up injection.
    /// Call this after every on-demand vision command.
    func applyVisionResult(_ result: VisionProviderResult?, summary: String,
                           mode: VisionMode = .describe,
                           frameDate: Date = Date(), frameID: UUID = UUID()) {
        state.visionIsLoading = false
        state.lastVisionSummary = summary
        state.lastCameraSummary = summary
        context.recordCamera(summary)
        if let r = result {
            state.lastVisionProvider    = r.providerUsed
            state.lastVisionModelUsed   = r.modelUsed ?? ""
            state.lastVisionImageSizeKB = r.imageSizeKB
            state.lastVisionTotalMs     = r.latencyMs
            state.lastVisionError       = r.error

            // Build structured VisionContext for conversational follow-up
            // ("what colour is it?", "what does it say?", "show me more").
            let vCtx = VisionContext(
                summary:           summary,
                mode:              mode,
                frameID:           frameID,
                frameTimestamp:    frameDate,
                analysisTimestamp: Date(),
                detectedEntities:  r.detectedEntities,
                clothingItems:     [],   // populated by describePerson JSON → accessories
                accessories:       [],
                heldObjects:       [],
                ocrText:           [],
                confidenceScore:   r.confidenceScore,
                providerUsed:      r.providerUsed
            )
            state.lastVisionContext = vCtx
        }
        if prefs.current.visionSaveToMemory {
            let entry = "Visual observation [\(Date().formatted())]: \(summary)"
            memories?.remember(entry, tags: "vision,camera")
        }
        // Active-context push: "what colour is it" / "describe it more" can
        // now refer back to this scene.  High priority so a follow-up
        // immediately after a describe call resolves to the camera, not to
        // an older Shopify list.
        if !summary.isEmpty {
            activeContext.record(
                source: .camera,
                title: "Camera scene",
                summary: summary,
                priority: 2,
                suggestedActions: [.describeMore])
        }
    }

    func captureCameraAndDescribe(announce: Bool = false,
                                  mode: VisionMode = .describe) async -> String {
        // Route through cameraAwareness.captureDescription() — this uses the
        // dedicated MiniMaxVisionProvider (vision model) rather than the text
        // LLM router.  The legacy vision.analyze() path used the text model
        // which has no image understanding and outputs <thinking> blocks.
        let captureStart = Date()
        let (summary, result) = await cameraAwareness.captureDescription(mode: mode)
        state.lastVisionCaptureMs = Int(-captureStart.timeIntervalSinceNow * 1000)
        state.lastVisionTimestamp = Date()
        applyVisionResult(result, summary: summary, mode: mode)
        if announce { speak(summary) }
        return summary
    }

    func captureCameraScene(announce: Bool = true) async {
        let scene = await cameraAwareness.captureScene()
        state.lastSceneSummary = scene.summary
        state.lastSceneOCR = scene.ocrLines
        state.lastSceneTimestamp = scene.timestamp
        state.lastCameraSummary = scene.summary
        state.faceCount = scene.peopleCount
        context.recordCameraScene(scene)
        overlayManager.open(.camera)
        state.sessionLastOverlayKind = .camera
        if announce { speak(scene.summary) }
        snapshots?.save(
            phase: state.phase.rawValue,
            lastIntent: "captureCamera",
            lastResponse: scene.summary,
            sessionId: sessionId
        )
    }

    func startCameraWatch() {
        guard !cameraAwareness.isWatching else {
            speak(renderer.render(ResponseKey.cameraWatchAlready))
            return
        }
        cameraAwareness.startWatching(intervalSeconds: prefs.current.cameraWatchIntervalSeconds)
        state.cameraWatchActive = true
        speak(renderer.render(ResponseKey.cameraWatchRoom))
    }

    func stopCameraWatch() {
        cameraAwareness.stopWatching()
        state.cameraWatchActive = false
    }

    func handleScreenCapture(announce: Bool = true) async {
        do {
            let summary = try await screenAwareness.analyse()
            state.screenSummary = summary
            state.activeApp = summary.appName
            overlayManager.open(.screen)
            state.sessionLastOverlayKind = .screen
            if announce { speak(summary.assistantSummary) }
            context.recordScreen(summary.assistantSummary)
            context.recordAction("screen: \(summary.ocrSummary.prefix(60))")
            snapshots?.save(
                phase: state.phase.rawValue,
                lastIntent: "captureScreen",
                lastResponse: summary.assistantSummary,
                sessionId: sessionId
            )
        } catch {
            let msg = "Screen capture failed: \(error.localizedDescription)"
            state.log("screen", .error, msg)
            if announce { speak(renderer.render(ResponseKey.screenCaptureFailed)) }
        }
    }

    func startScreenWatch() {
        guard !screenAwareness.isWatching else { return }
        screenAwareness.onWatchEvent = { [weak self] event in
            guard let self else { return }
            self.state.screenSummary = event.summary
            self.state.activeApp = event.summary.appName
            if event.appChanged {
                self.context.recordScreen(event.summary.assistantSummary)
            }
        }
        screenAwareness.startWatching(intervalSeconds: prefs.current.screenWatchIntervalSeconds)
        state.screenWatchActive = true
        Log.ui.info("screen watch started")
    }

    func stopScreenWatch() {
        screenAwareness.stopWatching()
        state.screenWatchActive = false
        Log.ui.info("screen watch stopped")
    }

    func showCommandCentre() {
        state.commandCentreVisible = true
        if let win = mainWindow(), !win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        }
    }

    func hideCommandCentre() {
        state.commandCentreVisible = false
        if let win = mainWindow(), win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        }
    }

    func toggleCommandCentre() {
        if state.commandCentreVisible { hideCommandCentre() } else { showCommandCentre() }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }

    // MARK: - Device selection

    func selectMicrophone(named query: String?) {
        guard let query, !query.isEmpty else { return }
        let lower = query.lowercased()
        if let match = state.availableMicrophones.first(where: { $0.name.lowercased().contains(lower) }) {
            audioDevices.setPreferred(match)
            state.preferredMicrophoneUID = match.id
            state.activeMicrophoneName = match.name
        }
    }

    func selectCamera(named query: String?) {
        guard let query, !query.isEmpty else { return }
        let lower = query.lowercased()
        if let match = state.availableCameras.first(where: { $0.name.lowercased().contains(lower) }) {
            camera.setPreferred(match)
            state.preferredCameraUID = match.id
            do { try camera.startPreview() } catch {
                state.cameraStatus = .failed(error.localizedDescription)
            }
        }
    }

    func refreshAudioDevices() {
        state.availableMicrophones = audioDevices.enumerate()
        state.activeMicrophoneName = audioDevices.resolvePreferred()?.localizedName
        state.log("audio", .info, "audio devices refreshed (\(state.availableMicrophones.count) inputs)")
    }

    func setSpeechEngine(_ engine: SpeechEngine) {
        prefs.update { $0.speechEngine = engine }
        state.speechEngine = engine
        // Don't restart in-flight session; next startListening picks the new engine.
    }

    func setWhisperModelPath(_ path: String?) {
        prefs.update { $0.whisperModelPath = path }
    }

    // MARK: - Pending conversation context

    /// Store a question Jarvis just asked — automatically enters
    /// `.awaitingResponse` on the next TTS-end event.
    func setPendingContext(_ context: PendingConversationContext) {
        activePendingContext = context
        state.pendingQuestion = context.assistantQuestion
        state.awaitingResponseActive = true
        state.awaitingResponseType = context.expectedResponseType.rawValue
        conversation.setPendingContext(context)   // publishes ConversationFollowUpRequestedEvent
        state.log("conv", .info,
            "pending_context_set type=\(context.expectedResponseType.rawValue) q=\"\(context.assistantQuestion.prefix(60))\"")
    }

    /// Remove the pending context (answered, timed out, or session ended).
    func clearPendingContext(resolution: String = "cleared") {
        guard activePendingContext != nil else { return }
        state.lastFollowUpResolution = resolution
        activePendingContext = nil
        awaitingResponseTimeoutTask?.cancel()
        awaitingResponseTimeoutTask = nil
        state.pendingQuestion = ""
        state.awaitingResponseActive = false
        state.awaitingResponseType = ""
        conversation.clearPendingContext(resolution: resolution)  // publishes FollowUpResolvedEvent
        state.log("conv", .info, "pending_context_cleared resolution=\(resolution)")
    }

    /// Starts a 20-second watchdog that clears the pending context if no
    /// reply arrives.  The awaitingResponse STT session has its own shorter
    /// silence timeout; this outer guard handles the case where the user
    /// wanders off before speaking at all.
    private func scheduleAwaitingResponseTimeout() {
        awaitingResponseTimeoutTask?.cancel()
        awaitingResponseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 s
            guard let self, !Task.isCancelled else { return }
            guard self.activePendingContext != nil else { return }
            self.state.log("conv", .info, "awaiting_response_timeout — clearing pending context")
            self.clearPendingContext(resolution: "timeout")
            // Stay in conversationalArmed if still active.
            if !self.conversationalArmed {
                self.returnToPassiveWake(reason: .silenceTimeout)
            }
        }
    }

    // MARK: - TTS speaking observer

    /// (Re-)wires the task that mirrors `tts.isSpeakingStream` into AppState
    /// and drives the post-speech lifecycle. Must be called at startup and
    /// whenever `tts` is swapped to a different engine — the stream captured
    /// at bootstrap is engine-specific and becomes stale after a switch.
    private func rewireSpeakingObserver() {
        speakingObserverTask?.cancel()
        let speakingStream = tts.isSpeakingStream
        speakingObserverTask = Task { @MainActor [weak self] in
            for await speaking in speakingStream {
                guard let self else { return }
                self.state.isSpeaking = speaking
                if speaking {
                    self.timingEngine.jarvisStartedSpeaking()
                    self.state.phase = .speaking
                    self.latency.mark(.ttsStart)
                    let prevSp = self.state.listeningActualState.displayName
                    self.state.listeningActualState = .speaking
                    self.state.pushLifecycleEvent(from: prevSp, to: "speaking", reason: "tts_started")
                    // Re-arm wake word so "Jarvis" can interrupt mid-speech.
                    self.restartWakeWordIfNeeded()
                } else {
                    self.timingEngine.jarvisStoppedSpeaking()
                    StreamingConversationEngine.shared.advanceIfStreaming()
                    self.latency.mark(.ttsComplete)
                    let prevSp2 = self.state.listeningActualState.displayName
                    self.state.listeningActualState = self.state.listeningEnabled ? .wakeWordListening : .idleListening
                    self.state.pushLifecycleEvent(from: prevSp2, to: self.state.listeningActualState.displayName, reason: "tts_finished")
                    self.latency.measure(from: .ttsStart, to: .ttsComplete, recordAs: .ttsComplete)
                    SystemBus.shared.publish(TTSFinishedEvent(
                        correlationID: ExecutionTracer.shared.activeCorrelationID))
                    ExecutionTracer.shared.addStep("tts_finished", runtimeID: "audio")
                    ExecutionTracer.shared.complete()
                    // After TTS: decide whether to keep listening.
                    //
                    // Priority 1: pending question — always listen, enter .awaitingResponse.
                    // Priority 2: conversational window active — listen without wake word.
                    // Priority 3: return to passive wake.
                    self.state.log("conv", .info,
                        "tts_finished armed=\(self.conversationalArmed) sessionActive=\(self.conversationalSessionActive) hasPending=\(self.activePendingContext != nil) followUpEnabled=\(self.prefs.current.conversationalFollowUpEnabled) listeningEnabled=\(self.state.listeningEnabled)")
                    if self.activePendingContext != nil && self.state.listeningEnabled {
                        self.state.phase = .awaitingResponse
                        self.startConversationalListening()
                        self.scheduleAwaitingResponseTimeout()
                    } else if (self.conversationalArmed || self.conversationalSessionActive)
                       && self.prefs.current.conversationalFollowUpEnabled
                       && self.state.listeningEnabled {
                        self.conversationalSessionActive = true
                        self.startConversationalListening()
                    } else {
                        self.returnToPassiveWake(reason: .stateTransition)
                    }
                }
            }
        }
    }

    // MARK: - TTS configuration

    /// Switch between Apple System Voice and Piper ONNX.
    func setTTSEngine(_ engine: TTSEngine) {
        prefs.update { $0.ttsEngine = engine }
        switch engine {
        case .appleSystem:
            tts = appleTTS
        case .piper:
            piperTTS.configure(prefs: prefs.current)
            tts = piperTTS
        }
        // Re-wire observer to the new engine's stream — the old task is
        // watching a stream that no longer emits updates.
        rewireSpeakingObserver()
        refreshTTSState()
    }

    /// Update the Apple voice identifier. Pass nil to auto-select best male English voice.
    func setTTSVoice(_ identifier: String?) {
        prefs.update { $0.ttsVoiceIdentifier = identifier }
        appleTTS.configure(prefs: prefs.current)
        refreshTTSState()
    }

    func setTTSRate(_ rate: Float) {
        prefs.update { $0.ttsRate = rate }
        appleTTS.configure(prefs: prefs.current)
    }

    func setTTSPitch(_ pitch: Float) {
        prefs.update { $0.ttsPitch = pitch }
        appleTTS.configure(prefs: prefs.current)
    }

    func setTTSVolume(_ volume: Float) {
        prefs.update { $0.ttsVolume = volume }
        appleTTS.configure(prefs: prefs.current)
    }

    func setPiperExecutablePath(_ path: String?) {
        prefs.update { $0.piperExecutablePath = path }
        piperTTS.configure(prefs: prefs.current)
    }

    func setPiperModelPath(_ path: String?) {
        prefs.update { $0.piperModelPath = path }
        piperTTS.configure(prefs: prefs.current)
    }

    func setPiperConfigPath(_ path: String?) {
        prefs.update { $0.piperConfigPath = path }
        piperTTS.configure(prefs: prefs.current)
    }

    func setPiperSpeakerId(_ id: Int?) {
        prefs.update { $0.piperSpeakerId = id }
        piperTTS.configure(prefs: prefs.current)
    }

    /// Refreshes AppState TTS diagnostics from the currently active engine.
    func refreshTTSState() {
        state.ttsEngine = prefs.current.ttsEngine
        if let apple = tts as? AVSpeechTTS {
            if let v = apple.resolvedVoice {
                state.ttsVoiceName       = v.name
                state.ttsVoiceIdentifier = v.identifier
                state.ttsVoiceLanguage   = v.language
            } else {
                state.ttsVoiceName       = "System Default"
                state.ttsVoiceIdentifier = ""
                state.ttsVoiceLanguage   = ""
            }
        } else if let piper = tts as? PiperTTS {
            state.ttsVoiceName       = URL(fileURLWithPath: piper.modelPath).lastPathComponent
            state.ttsVoiceIdentifier = piper.modelPath
            state.ttsVoiceLanguage   = "custom"
        }
    }

    // MARK: - Web overlay bridge

    /// Syncs web overlay diagnostic counters into AppState so the Debug HUD stays current.
    func refreshWebOverlayState() {
        state.webOverlayBridgeMessages = webOverlayManager.totalBridgeMessages
        state.webOverlayLastMessage    = webOverlayManager.bridgeLastMessage
        state.webOverlayLastError      = webOverlayManager.bridgeLastError
    }

    /// Handles inbound messages from any managed web overlay via the JS bridge.
    private func handleWebBridgeMessage(_ type: WebBridgeInbound,
                                         payload: [String: Any]?) {
        // Keep AppState diagnostics fresh on every message.
        refreshWebOverlayState()

        switch type {

        case .closeOverlay:
            overlayManager.closeTop()

        case .speakText:
            // Cap at 300 chars — prevents runaway TTS from malicious/broken web content
            if let rawText = payload?["text"] as? String, !rawText.isEmpty {
                let text = String(rawText.prefix(300))
                if rawText.count > 300 {
                    Log.app.warning("[webview] speakText truncated from \(rawText.count) to 300 chars")
                }
                speak(text)
            }

        case .requestContext:
            // Respond with a lightweight context snapshot.
            let ctx: [String: Any] = [
                "activeApp": state.activeApp,
                "lastSpoken": state.lastSpoken,
                "phase": state.phase.rawValue,
                "isSpeaking": state.isSpeaking,
                "isListening": state.isListening
            ]
            // Broadcast to whichever overlay sent the request (best-effort — all open web overlays).
            for kind in webOverlayManager.containers.keys {
                webOverlayManager.push(to: kind, type: "contextUpdate", payload: ctx)
            }

        case .requestNews:
            // Respond with recent article metadata.
            let articles: [[String: Any]] = newsStore.articles.prefix(30).map { a in
                [
                    "title":  a.title,
                    "source": a.sourceName,
                    "url":    a.url,
                    "age":    Int(-a.publishedAt.timeIntervalSinceNow)
                ]
            }
            for kind in webOverlayManager.containers.keys {
                webOverlayManager.push(to: kind, type: "newsUpdate",
                                        payload: ["articles": articles])
            }

        case .openURL:
            if let urlStr = payload?["url"] as? String,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               ["https", "http"].contains(scheme) {
                NSWorkspace.shared.open(url)
            } else if let urlStr = payload?["url"] as? String {
                Log.app.warning("[webview] openURL blocked non-http(s) scheme: \(urlStr, privacy: .public)")
            }
        }
    }

    // MARK: - Vision / motion

    private func handleFrame(_ frame: CGImage) {
        guard state.watchingDesk else { return }
        let reading = motion.evaluate(frame)
        state.motionDetected = reading.motion
        if reading.motion,
           Date().timeIntervalSince(motionLastSummary) > 8 {
            motionLastSummary = Date()
            state.log("vision", .info,
                      "desk motion delta=\(String(format: "%.3f", reading.delta))")
            context.recordCamera("motion delta \(reading.delta)")
        }
    }

    func beginWatchingDesk() {
        state.watchingDesk = true
        motion.reset()
        speak(renderer.render(ResponseKey.cameraWatchDeskStarted))
    }

    func stopWatchingDesk() {
        state.watchingDesk = false
    }

    // MARK: - Reddit bridge (RedditOverlayView calls these on JarvisController directly)

    typealias RedditSummaryKind = RedditIntentHandler.SummaryKind

    @discardableResult
    func summariseRedditText(title: String, body: String, kind: RedditSummaryKind) async -> String? {
        return await redditIntentHandler.summariseText(title: title, body: body, kind: kind)
    }

    // MARK: - Home Assistant

    private static func buildSmartHomeClient(from prefs: PreferencesStore) -> SmartHomeClient {
        guard let base = prefs.current.smartHomeBaseURL,
              let url = URL(string: base),
              let token = prefs.smartHomeToken,
              !token.isEmpty
        else { return DisabledSmartHomeClient() }
        return HomeAssistantRESTClient(baseURL: url, token: token)
    }

    func refreshSmartHomeFromPrefs() async {
        smartHome = Self.buildSmartHomeClient(from: prefs)
        // Re-wire alias store into the freshly built REST client.
        if let haClient = smartHome as? HomeAssistantRESTClient {
            haClient.aliasStore = homeAliases
        }
        state.homeAssistantStatus = smartHome.isConfigured ? .ready : .unavailable("Not configured")
        if smartHome.isConfigured { await refreshHomeAssistant() }
    }

    func refreshHomeAssistant() async {
        do {
            let entities = try await smartHome.getStatus()
            lastKnownEntities = entities
            state.homeEntitiesCount = entities.count
            state.homeSummary = "\(entities.count) entities"
            state.homeAssistantStatus = .ready
            context.recordHome(state.homeSummary)
        } catch {
            state.homeAssistantStatus = .failed(error.localizedDescription)
            state.log("home", .warn, "HA refresh failed: \(error.localizedDescription)")
        }
    }

    func homeStatusSummary() async -> String {
        if !smartHome.isConfigured {
            return "Home Assistant isn't configured. Add the base URL and token in Settings."
        }
        await refreshHomeAssistant()
        if lastKnownEntities.isEmpty {
            return "Home Assistant is configured but returned no entities. Check your URL and token in Settings."
        }
        let lights = lastKnownEntities.filter { $0.entityID.hasPrefix("light.") }
        let lightsOn = lights.filter { $0.state == "on" }.count
        let switches = lastKnownEntities.filter { $0.entityID.hasPrefix("switch.") && $0.state == "on" }.count
        var parts: [String] = ["Home Assistant is connected. \(lastKnownEntities.count) entities found."]
        if !lights.isEmpty {
            parts.append("\(lightsOn) of \(lights.count) lights are on.")
        }
        if switches > 0 {
            parts.append("\(switches) switch\(switches == 1 ? "" : "es") active.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Android event receiver helpers

    /// Sync PreferencesStore android-event settings into the receiver.
    /// Call once at bootstrap and whenever prefs change.
    func syncAndroidEventReceiverPrefs(_ receiver: AndroidEventReceiver? = nil) {
        let r = receiver ?? androidEventReceiver
        guard let r else { return }
        let p = prefs.current
        r.speakCallerNames        = p.androidSpeakCallerNames
        r.speakMessageSenders     = p.androidSpeakMessageSenders
        r.showMessagePreviews     = p.androidShowMessagePreviews
        r.autoOpenOverlay         = p.androidAutoOpenOverlay
        // Mirror mute toggles into the proactivity engine settings
        proactivity.settings.androidMuteSMS            = p.androidMuteSMS
        proactivity.settings.androidMuteWhatsApp       = p.androidMuteWhatsApp
        proactivity.settings.androidSpeakNotifications = p.androidSpeakNotifications
    }

    // MARK: - Android handoff

    func continueFromAndroid(context text: String, sourceID: String?) {
        receiveAndroidContext(text, sourceID: sourceID)
        showCommandCentre()
        if !text.isEmpty { speak(renderer.render(ResponseKey.androidFromPhone, ["text": text])) }
    }

    func receiveAndroidContext(_ text: String, sourceID: String?) {
        state.lastAndroidContext = text
        state.lastAndroidTimestamp = Date()
        context.recordAndroid(text)
        state.pushTimeline(TimelineEvent(timestamp: Date(),
                                         symbol: "iphone.and.arrow.forward",
                                         title: "Android",
                                         detail: text.prefix(60).description))
    }

    func contextSnapshot() -> [String: String] {
        let snap = context.snapshot
        return [
            "phase": snap.phase.rawValue,
            "transcript": snap.currentTranscript,
            "last_command": snap.lastCommand,
            "android": snap.lastAndroidContext,
            "camera": snap.lastCameraSummary,
            "home": snap.lastHomeSummary,
            "active_app": snap.activeAppName,
            "recent": snap.recentActions.suffix(5).joined(separator: " | ")
        ]
    }

    func showContext() {
        showCommandCentre()
    }

    // MARK: - Status

    func statusSnapshot() -> [String: String] {
        [
            "microphone": state.microphoneStatus.label,
            "speech":     state.speechStatus.label,
            "camera":     state.cameraStatus.label,
            "android":    state.androidServerStatus.label,
            "wake":       state.wakeWordStatus.label,
            "home":       state.homeAssistantStatus.label,
            "engine":     state.speechEngine.displayName,
            "offline":    String(state.isOffline),
            "listening":  String(state.isListening),
            "speaking":   String(state.isSpeaking),
            "clients":    String(state.connectedClients),
            "port":       String(state.webSocketPort)
        ]
    }

    func statusSpoken() -> String {
        let mic = state.microphoneStatus.isHealthy ? "microphone ready" : "microphone \(state.microphoneStatus.label.lowercased())"
        let cam = state.cameraStatus.isHealthy ? "camera ready" : "camera \(state.cameraStatus.label.lowercased())"
        let wake = state.isWakeArmed ? "wake word armed" : "wake word off"
        let engine = "engine: \(state.speechEngine.displayName)"
        return "Status: \(mic), \(cam), \(wake), \(engine)."
    }

    // MARK: - Text helpers

    /// Apply a spoken-reply cap matching Android's ResponseFormatter rules.
    ///
    /// Remote replies are spoken by the Android or Windows TTS engine.  Android's
    /// `ResponseFormatter` caps at 3 sentences / 320 chars, so this function mirrors
    /// that contract on the Mac side before the reply is sent over the wire.
    ///
    /// Rules applied in order:
    ///   1. Whitespace-only guard — returns empty string (caller must handle).
    ///   2. Strip leading/trailing whitespace.
    ///   3. Cap at `maxSentences` sentences (3 by default).
    ///   4. Hard-cap at `maxChars` (320 by default), breaking on sentence boundary.
    func cappedForRemoteTts(_ text: String, maxSentences: Int = 3, maxChars: Int = 320) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Split on sentence-ending punctuation followed by whitespace.
        // This mirrors ResponseFormatter.splitSentences() in Android.
        var sentences: [String] = []
        var current = ""
        for char in trimmed {
            current.append(char)
            if (char == "." || char == "!" || char == "?") {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        // Remaining non-punctuated tail
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        let capped = sentences.prefix(maxSentences).joined(separator: " ")
        guard capped.count > maxChars else { return capped }

        // Hard char cap — prefer sentence boundary inside the limit.
        let truncated = String(capped.prefix(maxChars))
        let terminators: [Character] = [".", "!", "?"]
        if let lastTerm = truncated.lastIndex(where: { terminators.contains($0) }),
           truncated.distance(from: truncated.startIndex, to: lastTerm) > maxChars / 2 {
            return String(truncated[...lastTerm]).trimmingCharacters(in: .whitespaces)
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    /// Truncate `text` to at most `maxChars` characters, breaking on sentence
    /// boundaries where possible, for spoken summaries.
    private func shortSpeechExcerpt(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let cut = String(text.prefix(maxChars))
        // Prefer to end on a sentence boundary.
        let terminators: [Character] = [".", "!", "?"]
        if let last = cut.lastIndex(where: { terminators.contains($0) }) {
            return String(cut[...last])
        }
        // Fall back to cutting at last space to avoid mid-word truncation.
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace]) + "…"
        }
        return cut + "…"
    }
}
