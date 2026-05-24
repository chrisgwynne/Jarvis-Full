# Jarvis macOS Implementation Audit
*Generated: 2026-05-21*
*Files scanned: 284 Swift source files (main tree, excluding worktrees and generated code)*
*Test files: 20*

---

## Executive Summary

Jarvis is a substantially real macOS voice assistant. The core voice pipeline is production-quality. The breadth of integrations is genuinely impressive. However, approximately 20–25% of the visible feature surface is either partially wired, architecturally sound but requiring runtime configuration (API tokens, model files), or over-claimed relative to what is user-reachable without setup. No major area is a pure stub — every subsystem has real code.

**Overall maturity estimate:** ~72% of intended feature scope is implemented and wired. ~18% is partial or requires external configuration. ~10% is dead-end stubs or missing execution paths.

### Top 5 Implemented Wins
1. **Full voice pipeline** — Wake word (Sherpa ONNX + Apple fallback) → STT (Apple Speech + Whisper) → phrase match → intent route → TTS (Apple + Piper), all wired end-to-end in 8,269-line JarvisController.
2. **Sprint L Visual Intelligence (POI)** — `VisionDetectionPipeline`, `CameraFeedManager`, `RTSPStreamManager`, `VisionModule`, `POIHUDView`, `ObjectTracker`, `ThreatClassifier`, `MotionZoneEngine`, `SceneMemoryStore` all real, integrated, and producing data.
3. **GitHub Intelligence System (Sprint J)** — `GitHubModule` wraps 9 real sub-managers (PRs, issues, actions, code review, local repo index, roadmap analysis). All backed by real GitHub REST API calls with caching, circuit-breaking, and safety budget.
4. **Spatial Hand Tracking** — `HandTrackingEngine` runs real `VNDetectHumanHandPoseRequest` + `VNDetectFaceRectanglesRequest`, dominant-hand lock, secondary stability counter, face-contact rejection. `SpatialAmbientCoordinator` implements full state machine. Real gesture → overlay drag/resize paths.
5. **Android Bridge** — Full WebSocket protocol, heartbeat, capability negotiation, call control (answer/decline/hangup/speaker), WhatsApp voice/video call, SMS, contact call, camera capture. Real `AndroidBridgeAuth` validated by unit tests.

### Top 5 Gaps
1. **Web search** — `WebSearchProvider` protocol exists; only `NoopWebSearchProvider` is wired. No Brave, DuckDuckGo, or SerpAPI provider implemented. LLM fallback works but factual lookup is LLM-only.
2. **Email integration** — `Intent` has no email cases. No `EmailService`. Mentioned in `TODO.md` as "A2 — next sprint." Email follow-up is currently wired to a placeholder response that says "Email support coming soon."
3. **Apple Notes** — Not present. Mentioned in `TODO.md` as "A12 — easy win." No file, no intent, no phrase.
4. **Keychain storage** — All API tokens (HA, Todoist, GitHub, Shopify, Spotify) are stored in `preferences.json` in Application Support, not macOS Keychain. `LLM/Keychain.swift` exists but is not wired to the preferences path.
5. **RTSP null cleanup** — `RTSPStreamManager.stopAllDetectionLoops()` has a comment-only body: `// Implementation: RTSPStreamManager tracks detectionTasks by feedID`. Stopping all loops has no effect.

### Top 5 Misleading Items
1. `NoopWakeWord` is still in the file tree described as "Phase-1 placeholder" — this is the ultimate fallback when both Sherpa and Apple fail, not the real wake word.
2. `PlaceholderVisionAnalyzer` exists alongside the real `AppleVisionAnalyzer` and `LLMVisionAnalyzer`. It's only used in tests/previews but its presence and comment "Phase-2: stays around" is confusing.
3. The `bargeInSensitivity` preference field is explicitly commented "0.0–1.0 placeholder for future tuning" — no actual barge-in sensitivity is adjustable.
4. `RTSPStreamManager.stopAllDetectionLoops()` is called from `VisionModule.stop()` but has an empty implementation body (comment only).
5. `VisionSettings.MotionZoneDescriptor` default feed IDs are `UUID()` placeholders that need to be replaced with real feed IDs at runtime.

### Recommended Next 5 Phases
1. **Phase 1 — Stabilise & Harden** (1–2 sprints): Fix RTSP stop loop, move API tokens to Keychain, add web search provider (Brave/DuckDuckGo), fix `bargeInSensitivity` binding, add `privacy: .private` log annotations.
2. **Phase 2 — Email + Notes** (1 sprint): Apple Mail AppleScript integration (A2), Apple Notes (A12). Both are straightforward AppleScript + EventKit patterns already present in the codebase.
3. **Phase 3 — Vision Completeness** (1–2 sprints): Continuous ambient vision (`AmbientVisionService`), HA camera feed integration into POI grid, wire `haCamera` snapshot capture into detection pipeline.
4. **Phase 4 — Window Management** (1 sprint): `AXUIElement` based window move/resize/tile. `MacActionExecutor` is the natural home.
5. **Phase 5 — Production Hardening** (ongoing): Persistent conversation stress testing, LLM circuit-breaker tuning, memory cap enforcement, crash breadcrumb telemetry review.

---

## Status Matrix

| Area | Feature | Status | Key Files | User Reachable | Notes |
|------|---------|--------|-----------|----------------|-------|
| App Foundation | AppDelegate / main entry | ✅ | JarvisMacApp.swift | Yes | SwiftUI @main, WindowGroup |
| App Foundation | Menu bar / status bar | ✅ | StatusBar.swift | Yes | Menu with keyboard shortcuts |
| App Foundation | Overlay system | ✅ | OverlaySystem.swift | Yes | 25 OverlayKind cases, all marked isImplemented=true |
| App Foundation | Settings system | ✅ | SettingsView.swift | Yes | 16 tabs |
| App Foundation | Help system | ✅ | HelpOverlayView.swift, LivingDocumentationEngine.swift | Yes | Living docs with search |
| App Foundation | Crash breadcrumbs | ✅ | CrashBreadcrumbLog.swift | No (dev only) | |
| App Foundation | RuntimeCoordinator | ✅ | RuntimeCoordinator.swift, RuntimeRegistry.swift | No | Wired; thin shell subsystems |
| App Foundation | WebSocket server | ✅ | WebSocketServer.swift | Android bridge | |
| App Foundation | Android bridge | ✅ | AndroidBridge.swift, AndroidEventReceiver.swift | Yes (phone connected) | |
| App Foundation | Tailscale integration | ✅ | TailscaleService.swift | Yes (if Tailscale installed) | QR pairing |
| App Foundation | Permissions handling | ✅ | JarvisController bootstrap | Yes | Mic, speech, camera, screen |
| Conversation | Wake word (Sherpa) | ✅ | SherpaWakeWordService.swift | Yes (needs model file) | Needs .kws model path |
| Conversation | Wake word (Apple) | ✅ | AppleWakeWordService.swift | Yes | Auto-fallback |
| Conversation | STT Apple Speech | ✅ | SpeechRecognizer.swift | Yes | |
| Conversation | STT Whisper | ✅ | WhisperSpeechRecognizer.swift | Yes (needs model) | Needs GGUF model |
| Conversation | TTS Apple | ✅ | TextToSpeechService.swift | Yes | |
| Conversation | TTS Piper | ✅ | PiperTTS.swift | Yes (needs binary) | Needs piper executable + model |
| Conversation | Barge-in | ✅ | BargeInMonitor.swift, JarvisController | Yes | |
| Conversation | Phrase matcher | ✅ | CommandPhraseMatcher.swift, CommandPhraseDefaults.swift | Yes | ~1375 lines of defaults |
| Conversation | Intent router | ✅ | IntentRouter.swift | Yes | 2-tier: phrase + substring |
| Conversation | Follow-up resolver | ✅ | FollowUpResolver.swift, ConversationRuntime.swift | Yes | |
| Conversation | Multi-turn context | ✅ | PendingConversationContext.swift, ActiveContextRegistry.swift | Yes | |
| Conversation | LLM fallback (MiniMax) | ✅ | MiniMaxProvider.swift, LLMRouter.swift | Yes (needs token) | |
| Conversation | LLM fallback (Gemini) | ✅ | GeminiProvider.swift | Yes (needs API key) | |
| Conversation | LLM fallback (LM Studio) | ✅ | LMStudioProvider.swift | Yes (needs running instance) | |
| Conversation | LLM circuit breaker | ✅ | LLMProviderCircuitBreaker.swift | Yes (auto) | |
| Conversation | Fast response router | ✅ | FastResponseRouter.swift | Yes | Partial-transcript early exit |
| Conversation | Response templates | ✅ | ResponsePlaybook.swift, ResponseTemplateStore.swift | Yes | Editable in Settings |
| Conversation | Personality system | ✅ | PersonalityContextBuilder.swift, PersonalityFileStore.swift | Yes | |
| Conversation | Conversation router (Sprint K) | ✅ | ConversationRouter.swift | Yes | Dual-lane command vs. chat |
| Conversation | Unmatched command store | ✅ | UnmatchedCommandStore.swift, UnmatchedCommandsView.swift | Yes | Teaches new phrases |
| Conversation | Pronunciation dictionary | ✅ | PronunciationDictionary.swift, SpeechPreprocessor.swift | Yes | |
| Memory | SQLite database | ✅ | JarvisDatabase.swift, DatabaseMigrator.swift | Yes (auto) | WAL mode, FTS5 |
| Memory | Memory store CRUD | ✅ | MemoryStore.swift | Yes | |
| Memory | Conversation store | ✅ | ConversationStore.swift, ConversationMemoryStore.swift | Yes | |
| Memory | Conversation summariser | ✅ | ConversationSummariser.swift | Yes (needs LLM) | LLM compresses turns |
| Memory | Semantic memory index | ✅ | SemanticMemoryIndex.swift | Yes | NLEmbedding cosine search |
| Memory | Hybrid search | ✅ | SearchService.swift | Yes | FTS + semantic |
| Memory | Context snapshots | ✅ | ContextSnapshotStore.swift | Yes | |
| Memory | Preferences store | ✅ | PreferencesStore.swift | Yes | JSON in App Support |
| Memory | Keychain storage | ❌ | LLM/Keychain.swift | No | File exists, not wired to prefs |
| Vision / Screen | Apple Vision OCR | ✅ | AppleVisionAnalyzer.swift | Yes | |
| Vision / Screen | LLM vision (MiniMax) | ✅ | LLMVisionAnalyzer.swift, MiniMaxVisionProvider.swift | Yes (needs token) | |
| Vision / Screen | Camera capture (webcam) | ✅ | CameraManager.swift | Yes | Dual-role (primary/secondary) |
| Vision / Screen | Screen capture (ScreenCaptureKit) | ✅ | ScreenCaptureService.swift | Yes (needs permission) | |
| Vision / Screen | Screen OCR | ✅ | ScreenOCRService.swift | Yes | |
| Vision / Screen | Screen awareness / context | ✅ | ScreenAwarenessService.swift, ScreenContextAnalyzer.swift | Yes | |
| Vision / Screen | App/window awareness | ✅ | ActiveAppMonitor.swift, WindowContextMonitor.swift | Yes | NSWorkspace + CGWindowList |
| Vision / Screen | Privacy filter | ✅ | PrivacyFilter.swift | Yes (auto) | Blocks password managers, incognito |
| Vision / Screen | Ambient context engine | ✅ | AmbientContextEngine.swift | Yes | 30s normal, 8s watch mode |
| Vision / Screen | Reolink / RTSP camera feeds | ⚠️ | RTSPStreamManager.swift | Partial | Frames extracted, stopAll() no-op |
| Vision / Screen | HA camera snapshot viewer | ✅ | HASnapshotOverlayView.swift | Yes (needs HA) | |
| Visual Intelligence (L) | VisionModule (POI) | ✅ | VisionModule.swift | Yes | Coordinator for POI system |
| Visual Intelligence (L) | Detection pipeline | ✅ | VisionDetectionPipeline.swift | Yes | Vision rectangles + CoreML optional |
| Visual Intelligence (L) | Camera feed manager | ✅ | CameraFeedManager.swift | Yes | Multi-feed AVCapture + RTSP |
| Visual Intelligence (L) | Object tracker | ✅ | ObjectTracker.swift | Yes | IoU-based frame-to-frame tracking |
| Visual Intelligence (L) | Detection smoother | ✅ | DetectionSmoother.swift | Yes | |
| Visual Intelligence (L) | Threat classifier | ✅ | ThreatClassifier.swift | Yes | Rule-based threat levels |
| Visual Intelligence (L) | Motion zone engine | ✅ | MotionZoneEngine.swift | Yes | Zone-based motion alerts |
| Visual Intelligence (L) | Scene memory store | ✅ | SceneMemoryStore.swift | Yes | Event log |
| Visual Intelligence (L) | POI HUD overlay | ✅ | POIHUDView.swift | Yes | Grid/focus/cinematic modes |
| Visual Intelligence (L) | RTSP stream manager | ⚠️ | RTSPStreamManager.swift | Partial | stopAllDetectionLoops() empty body |
| Visual Intelligence (L) | CoreML object detection | ⚠️ | VisionDetectionPipeline.swift | Partial | Wired, requires user-supplied model file |
| Hand Tracking | Hand pose detection | ✅ | HandTrackingEngine.swift | Yes | VNDetectHumanHandPoseRequest |
| Hand Tracking | Dominant hand lock | ✅ | HandTrackingEngine.swift | Yes | Wrist-continuity tracking |
| Hand Tracking | Face rejection | ✅ | HandTrackingEngine.swift | Yes | |
| Hand Tracking | Gesture classifier | ✅ | GestureClassifier.swift | Yes | Pinch, palm, thumb-up etc. |
| Hand Tracking | Spatial cursor | ✅ | SpatialCursorEngine.swift | Yes | Deadzone + jump clamp |
| Hand Tracking | Radial HUD | ✅ | SpatialRadialHUD.swift | Yes | 8-action pinch-select |
| Hand Tracking | Overlay drag/resize | ✅ | SpatialAmbientCoordinator.swift | Yes | Two-hand resize with dwell gate |
| Hand Tracking | Accidental motion suppression | ✅ | AccidentalMotionDetector.swift | Yes | |
| Hand Tracking | Adaptive calibration | ✅ | GestureCalibrationStore.swift | Yes | Persisted learned thresholds |
| Hand Tracking | Gesture command registry | ✅ | GestureCommandRegistry.swift | Yes | Editable gesture→intent map |
| GitHub | GitHub API client | ✅ | GitHubAPIClient.swift | Yes (needs PAT) | REST v3 |
| GitHub | Notifications / overlay | ✅ | GitHubOverlayView.swift, GitHubProactivityProvider.swift | Yes | |
| GitHub | PR manager | ✅ | GitHubPRManager.swift | Yes | Open PRs, stale, files, reviews |
| GitHub | Issue manager | ✅ | GitHubIssueManager.swift | Yes | |
| GitHub | Actions manager | ✅ | GitHubActionsManager.swift | Yes | CI status |
| GitHub | Code review engine | ✅ | GitHubCodeReviewEngine.swift | Yes | LLM-backed if configured |
| GitHub | Local repo index | ✅ | GitHubLocalRepoIndex.swift | Yes | Shell grep for TODO/FIXME counts |
| GitHub | Roadmap analyzer | ✅ | GitHubRoadmapAnalyzer.swift | Yes | |
| GitHub | Project creation | ✅ | GitHubProjectCreationManager.swift | Yes | Safety-gated |
| GitHub | Safety manager | ✅ | GitHubSafetyManager.swift | Yes | Rate-limit budget |
| GitHub | Dashboard view | ✅ | GitHubDashboardView.swift | Yes | |
| Home Assistant | REST client | ✅ | HomeAssistantRESTClient.swift | Yes (needs config) | Full entity control |
| Home Assistant | WebSocket client | ✅ | HomeAssistantWebSocketClient.swift | Yes (needs config) | state_changed events + ping/pong |
| Home Assistant | Proactivity provider | ✅ | HomeAssistantProactivityProvider.swift | Yes | Door/lock/motion/smoke/vacuum |
| Home Assistant | Entity alias store | ✅ | HomeEntityAliasStore.swift | Yes | Spoken name → entity ID |
| Home Assistant | Entity registry | ✅ | HAEntityRegistry.swift | Yes | Synced from REST on startup |
| Home Assistant | Motion-camera mapper | ✅ | HAMotionCameraMapper.swift | Yes | Cooldown-aware |
| Home Assistant | Home overlay | ✅ | HomeOverlayView.swift | Yes | Room-grouped entity grid |
| Home Assistant | Automations | ✅ | JarvisController execute .homeRunAutomation | Yes | |
| Calendar | EventKit service | ✅ | EventKitCalendarService.swift | Yes | events, reminders |
| Calendar | Proactivity provider | ✅ | CalendarProactivityProvider.swift | Yes | 10-min + 1-min alerts |
| Calendar | Calendar overlay | ✅ | CalendarOverlayView.swift | Yes | |
| Todoist | API client | ✅ | TodoistAPIClient.swift | Yes (needs token) | REST v2 |
| Todoist | Proactivity provider | ✅ | TodoistProactivityProvider.swift | Yes | Morning overdue alert |
| Todoist | Tasks overlay | ✅ | TasksOverlayView.swift | Yes | |
| Weather | WeatherKit service | ✅ | WeatherService.swift | Yes (needs entitlement) | |
| Weather | Proactivity provider | ✅ | WeatherProactivityProvider.swift | Yes | Morning briefing, severe weather |
| Shopify | API client | ✅ | ShopifyAPIClient.swift | Yes (needs token) | Admin REST 2024-01 |
| Shopify | Proactivity provider | ✅ | ShopifyProactivityProvider.swift | Yes | |
| Shopify | Overlay | ✅ | ShopifyOverlayView.swift | Yes | |
| Spotify | API client | ✅ | SpotifyAPIClient.swift | Yes (needs token) | Personal token |
| Obsidian | Note model | ✅ | ObsidianNote.swift | Yes (needs vault path) | |
| Obsidian | Vault service | ✅ | ObsidianVaultService.swift | Yes | Incremental index, FTS+NLEmbedding |
| Obsidian | Proactivity provider | ✅ | ObsidianProactivityProvider.swift | Yes | |
| Obsidian | Overlay | ✅ | ObsidianOverlayView.swift | Yes | |
| Obsidian | RAG injection | ✅ | JarvisController tryLLMFallback | Yes | |
| News | RSS/Atom fetcher | ✅ | RSSFetcher.swift, RSSParser.swift | Yes | |
| News | News store | ✅ | NewsStore.swift | Yes | |
| News | News overlay | ✅ | NewsOverlayView.swift | Yes | |
| News | Live news video | ✅ | LiveNewsPlayerView.swift | Yes (WKWebView) | YouTube/HLS channels |
| News | News labeller | ✅ | NewsLabeller.swift | Yes | LLM-backed categorisation |
| News | Proactivity | ✅ | NewsRefreshScheduler.swift | Yes | |
| Reddit | Reddit client | ✅ | RedditClient.swift | Yes | No OAuth, public JSON API |
| Reddit | Reddit store | ✅ | RedditStore.swift | Yes | |
| Reddit | Reddit overlay | ✅ | RedditOverlayView.swift | Yes | |
| SystemBus | Event bus | ✅ | SystemBus.swift | Yes (internal) | Typed pub/sub, 200-event ring |
| SystemBus | Event types | ✅ | SystemEventTypes.swift | Yes | 28+ event structs |
| SystemBus | Event store | ✅ | EventStore.swift | Yes | 1000-event ring + query |
| SystemBus | Task thread engine | ✅ | TaskThreadEngine.swift | Yes | App-focus thread tracking |
| SystemBus | App context adapter | ✅ | AppContextAdapter.swift | Yes | Cursor, Xcode, Terminal, Safari |
| Proactivity | Engine | ✅ | ProactivityEngine.swift | Yes | |
| Proactivity | Dedup store | ✅ | ProactivityDedupStore.swift | Yes | |
| Proactivity | Notification tray | ✅ | NotificationTrayView.swift | Yes | |
| Email | Email integration | ❌ | — | No | Not started. Placeholder responses only |
| Apple Notes | Notes integration | ❌ | — | No | Not started |
| Web Search | Search providers | ❌ | WebSearchProvider.swift | No | Protocol only, NoopProvider wired |
| Window Mgmt | AXUIElement window control | ❌ | — | No | Not started |

---

## Implemented Features (✅)

### Voice Pipeline (Core)
**Description:** Full wake word → STT → phrase match → intent route → TTS pipeline. 8,269-line JarvisController is the orchestrator.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Core/JarvisController.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Audio/SherpaWakeWordService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Audio/AppleWakeWordService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Audio/SpeechRecognizer.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Audio/TextToSpeechService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Phrases/CommandPhraseMatcher.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Core/IntentRouter.swift`

**How to trigger:** Say "Jarvis" (or press Cmd+Space for push-to-talk).

**Settings required:**
- Sherpa wake word: `Preferences > WakeWord > modelIdentifier` (path to .kws model)
- Whisper STT: `Preferences > speechEngine = .whisper`, `whisperModelPath`
- Piper TTS: `Preferences > ttsEngine = .piper`, `piperBinaryPath`, `piperModelPath`

**Known limitations:**
- Sherpa requires a separately downloaded model file.
- Whisper requires a GGUF model file.
- Apple Speech requires macOS Dictation to be enabled in System Settings.

### Persistent Conversation Sessions
**Description:** After wake, Jarvis listens for up to 10 minutes with follow-up awareness. No re-wake needed for follow-on commands.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Core/ConversationRuntime.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Conversation/FollowUpResolver.swift`

**How to trigger:** Auto-activated after first wake. Say "stop listening" to end.

### Multi-Turn Conversation
**Description:** Jarvis can ask clarifying questions and await answers before executing. Uses `PendingConversationContext` with yesNo/choice/freeform types.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Conversation/PendingConversationContext.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Conversation/FollowUpResolver.swift`

### Dual-Lane Conversation Router (Sprint K)
**Description:** Every transcript is first classified as a command, memory update, knowledge query, project reflection, or general chat. Non-command lanes are routed to `JarvisAnswerComposer` with knowledge retrieval before hitting the LLM.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Conversation/ConversationRouter.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Conversation/JarvisAnswerComposer.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Knowledge/ProjectKnowledgeService.swift`

### LLM Fallback (MiniMax + Gemini + LM Studio)
**Description:** When no phrase or substring match fires, the transcript goes to an LLM. The LLM returns a structured JSON response mapping to an `Intent` case and optional spoken text. Three provider chain with circuit-breaker.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/LLM/LLMRouter.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/LLM/MiniMaxProvider.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/LLM/GeminiProvider.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/LLM/LMStudioProvider.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/LLM/LLMIntentBridge.swift`

**Settings required:** At least one of: MiniMax token (`miniMaxAPIKey`), Gemini API key (`geminiAPIKey`), LM Studio running at `lmStudioBaseURL`.

### Memory System (SQLite + Semantic)
**Description:** Persistent SQLite database with FTS5 full-text search. Semantic NLEmbedding index for cosine-similarity retrieval. Hybrid search combines both. Conversation summariser compresses old turns.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Memory/JarvisDatabase.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Memory/MemoryStore.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Memory/SemanticMemoryIndex.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Memory/SearchService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Memory/ConversationSummariser.swift`

**Example commands:** "Remember that I'm using SQLite for the database", "What do you remember about the database?", "Search for memory: project deadline"

### Screen Awareness
**Description:** ScreenCaptureKit snapshot + Vision OCR + context analysis. Detects active app, window title, visible text, errors. Ambient engine polls at 30s/8s. Privacy filter blocks sensitive apps.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Screen/ScreenCaptureService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Screen/ScreenAwarenessService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Screen/ScreenOCRService.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Ambient/AmbientContextEngine.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Ambient/PrivacyFilter.swift`

**Settings required:** Screen Recording permission in macOS System Settings.

**Example commands:** "What am I working on?", "What failed on screen?", "Watch this", "What can you see?"

### POI Visual Intelligence (Sprint L)
**Description:** Multi-camera surveillance HUD with person/face/object detection via Vision framework. Supports local webcam and RTSP streams. Object tracker, threat classifier, motion zones, scene memory. Optional CoreML model for richer object classes.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/VisionModule.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/VisionDetectionPipeline.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/CameraFeedManager.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/RTSPStreamManager.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/POIHUDView.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/ThreatClassifier.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Vision/MotionZoneEngine.swift`

**Example commands:** "Show surveillance", "Start surveillance", "What do you see?", "Who is at the door?", "Any people detected?", "Show threat status"

**Known limitations:** RTSP stop loop is a no-op (bug). CoreML model must be user-supplied. Default detection uses Vision rectangles only (person, face).

### Spatial Hand Tracking
**Description:** `VNDetectHumanHandPoseRequest` tracks hand in real time. Pinch opens a radial HUD. Palm-open closes. Overlay drag with finger-tip cursor. Two-hand spread resizes overlays. Dominant-hand lock, face-rejection, accidental-motion suppression, adaptive calibration.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/HandTrackingEngine.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/SpatialInteractionCoordinator.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/GestureClassifier.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/SpatialCursorEngine.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/SpatialRadialHUD.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/SpatialInteraction/GestureCalibrationStore.swift`

**Example commands:** "Spatial mode" (voice), or just use hand gestures in front of webcam.

### GitHub Intelligence (Sprint J)
**Description:** Full GitHub developer intelligence with 9 sub-managers. Lists PRs, issues, CI status, code review, local repo scan, roadmap analysis. Cached REST calls with safety budget. Dashboard overlay.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/GitHub/GitHubModule.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/GitHub/GitHubPRManager.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/GitHub/GitHubIssueManager.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/GitHub/GitHubActionsManager.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/GitHub/GitHubCodeReviewEngine.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/UI/GitHubDashboardView.swift`

**Settings required:** `githubPersonalAccessToken` with `notifications` + `repo` scope.

**Example commands:** "Check GitHub", "Show open PRs", "Any stale pull requests in jarvis?", "What are the open issues?", "Check CI status", "GitHub dashboard"

### Android Bridge
**Description:** Full WebSocket protocol for Mac↔Android communication. Call control (answer/decline/hangup/speaker), WhatsApp voice/video call, SMS send, contact call, camera capture, heartbeat, capability negotiation. Tailscale QR pairing.

**Key files:**
- `/Users/chris/Desktop/jarvis/JarvisMac/Networking/AndroidBridge.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Networking/AndroidEventReceiver.swift`
- `/Users/chris/Desktop/jarvis/JarvisMac/Networking/TailscaleService.swift`

**Example commands:** "Call Mike", "Send WhatsApp to Cath saying I'm on my way", "Answer it", "Hang up", "What's my phone battery?"

### Home Assistant
**Description:** Full REST + WebSocket integration. Entity control (lights, locks, fans, vacuum, covers). Proactive alerts for doors/motion/smoke. Entity aliases. Room-grouped overlay.

**Settings required:** `smartHomeBaseURL`, `smartHomeToken`.

**Example commands:** "Turn on the kitchen lights", "Lock the front door", "Set the living room to 50%", "Show home panel"

### Integrations (Calendar, Todoist, Weather, Shopify, Spotify, Obsidian)
All six are fully implemented with real API clients, proactivity providers, and overlays. Each requires its respective API token/path in Settings.

### News System
**Description:** RSS/Atom fetcher for configurable feeds, Hacker News Algolia API, live YouTube/HLS video channels, LLM-backed labelling and summarisation, proactivity alerts.

**Example commands:** "Show me the news", "Watch Bloomberg", "Summarise the news", "Open the first story"

### Reddit
**Description:** Unauthenticated Reddit public JSON API. Subreddit browsing, post list, comment tree, LLM summarisation of posts and comments.

**Example commands:** "Show Reddit", "Open r/programming", "Summarise this post", "What are the comments saying?"

### Living Documentation / Help
**Description:** `LivingDocumentationEngine` with pluggable `DocumentationContributor` protocol. Sections reflect live app state. Searchable help overlay.

**Example commands:** "Show help", "What can you do?", "How do I call someone?"

### Timers and Stopwatch
**Description:** Multiple named timers, auto-naming (Timer 1, Timer 2), stopwatch. Expiry fires proactivity signal and TTS.

**Example commands:** "Set a 5 minute timer", "Set a pizza timer for 20 minutes", "Start the stopwatch", "Cancel all timers"

---

## Partial Features (⚠️)

### RTSP Stream Detection Stop
**What exists:** `RTSPStreamManager` creates AVPlayer for each stream, extracts frames via periodic tasks, feeds `VisionDetectionPipeline`.

**What's missing:** `stopAllDetectionLoops()` has an empty body (comment only: "Implementation: RTSPStreamManager tracks detectionTasks by feedID"). When `VisionModule.stop()` calls this, RTSP detection loops continue running in the background.

**Impact:** Memory/CPU leak when user stops surveillance. High severity.

**Fix:** Iterate `detectionTasks` and cancel each task.

### CoreML Object Detection
**What exists:** `VisionDetectionPipeline.loadCoreMLModel(at:)` compiles and loads a model. `runObjectDetection()` applies it via `VNCoreMLRequest`. Label-to-class mapping exists.

**What's missing:** No bundled CoreML model. The user must supply a YOLO/other model path and call `loadCoreMLModel`. No Settings UI for this. Without a model, object detection only detects persons and faces.

**Fix:** Bundle a lightweight MobileNetV3 or NanoYOLO model, or add a Settings path to load a user-supplied one.

### Web Search
**What exists:** `WebSearchProvider` protocol, `WebSearchResults` model, `NoopWebSearchProvider` as the wired default. JarvisController has a `webSearch` property and calls it in the conversational path.

**What's missing:** No real provider (Brave, DuckDuckGo, SerpAPI). All searches fall through to LLM-only answers.

**Fix:** Implement `BraveSearchProvider` or `DDGProvider` with API key in Settings.

### Barge-In Sensitivity
**What exists:** `bargeInSensitivity: Float` field in `Preferences`. `BargeInMonitor.swift` exists.

**What's missing:** The preference comment says "0.0–1.0 placeholder for future tuning". It's not connected to any threshold in the barge-in logic. The Settings slider saves the value but nothing reads it.

### Attention Engine
**What exists:** `AttentionEngine.swift` is a real rule-based evaluator (idle seconds, media apps, fullscreen). `AttentionState` enum with relevant states.

**What's missing:** `AttentionEngine` is instantiated in `JarvisController` (`let attention = AttentionEngine()`) but it is not found being started or consulted in the bootstrap or execute paths in the scanned code. May be partially disconnected from the main flow.

---

## Stubbed Features (🧪)

### Email Integration
**Files:** None (no implementation files exist)

**What it claims:** `Intent` enum has no email cases. JarvisController has a single placeholder response method around line 6387 that returns a `reply_yes_email_placeholder` label when email-like follow-up context is detected. The spoken response says "Email support coming soon."

**Why not real:** Apple Mail integration was listed as "next sprint" in CLAUDE.md. No `EmailService`, no AppleScript runner for Mail, no `Intent.readEmail`, no `Intent.replyToEmail`.

**Risk:** Low confusion risk — no voice phrase maps to email intents. The placeholder only fires in an edge-case follow-up resolution path.

### Apple Notes
**Files:** None

**What it claims:** Mentioned in CLAUDE.md `TODO.md` as "A12 — Apple Notes — easy win."

**Why not real:** Not started. No file, no intent case, no phrase.

### NoopWakeWord (Fallback)
**Files:** `/Users/chris/Desktop/jarvis/JarvisMac/Audio/WakeWordService.swift` lines 56–82

**What it claims:** A `WakeWordDetecting` conformance. `isRunning` becomes true after `start()`. Never fires a wake event.

**Why this matters:** When both Sherpa and Apple fail, this is wired in. The watchdog sees `wakeWord.isRunning == true` but the user can't trigger anything. Confusing UX if neither real wake word works.

### Keychain Storage
**Files:** `/Users/chris/Desktop/jarvis/JarvisMac/LLM/Keychain.swift`

**What it claims:** The file exists. The CLAUDE.md audit section mentions "Move 5 API tokens to Keychain."

**Why not real:** The `Keychain.swift` file exists in the LLM folder but is not imported or called from `PreferencesStore`. All tokens go to `preferences.json` at `~/Library/Application Support/JarvisMac/preferences.json`.

### Motion Zone Default Feed IDs
**Files:** `/Users/chris/Desktop/jarvis/JarvisMac/Vision/MotionZoneEngine.swift` line 35

**What it claims:** Starter motion zones are included.

**Why not real:** The default zones use `cameraFeedID: UUID()` — a fresh random UUID on every launch, never matching any real feed ID. Zone alerts never fire from defaults.

---

## Missing Features (❌)

### Email Integration (A2)
**Roadmap expectation:** Apple Mail AppleScript — read inbox, VIP + keyword proactivity, reply via voice.

**Recommended phase:** Phase 2 (1 sprint). The AppleScript runner at `Actions/AppleScriptRunner.swift` already exists.

### Apple Notes (A12)
**Roadmap expectation:** `tell application "Notes" to make new note` via AppleScript.

**Recommended phase:** Phase 2 (half a sprint). Trivially simple given existing AppleScript infrastructure.

### Web Search Provider
**Roadmap expectation:** Real-time web search before LLM fallback. Brave API or DuckDuckGo.

**Recommended phase:** Phase 1 (1–2 days). Protocol is already defined.

### Window Management (A11)
**Roadmap expectation:** AXUIElement-based window move/resize/tile, multi-display support.

**Recommended phase:** Phase 4 (1 sprint).

### Continuous Ambient Vision (A6)
**Roadmap expectation:** `AmbientVisionService` doing background camera analysis, separate from on-demand capture.

**Recommended phase:** Phase 3. The POI `VisionModule` brings much of this infrastructure now.

---

## Deviations Worth Keeping (🧭)

### Living Documentation Engine
**What exists:** `LivingDocumentationEngine` + `DocumentationContributor` protocol producing real-time help docs that reflect current config state.

**Why valuable:** Self-documenting apps are rare. The search + section system is genuinely useful for onboarding.

**Suggested placement:** Keep as a core capability. Wire more contributors (Spotify, Reddit, GitHub Intelligence).

### Dual-Lane Conversation Router (Sprint K)
**What exists:** `ConversationRouter` classifies every utterance before it hits the command pipeline. Project-reflection and knowledge-query lanes use `ProjectKnowledgeService` for RAG before the LLM.

**Why valuable:** Transforms Jarvis from a command executor into a project-aware conversational partner. Not in the original roadmap.

**Suggested placement:** Core feature. Expand with more knowledge sources (GitHub issues as project facts, Todoist tasks as current work context).

### Question Classifier
**What exists:** `QuestionClassifier.swift` classifies utterances (yes/no, confirmation, freeform, question, command) before routing.

**Why valuable:** Reduces false-positive follow-up resolution. Unit tested.

### Attention Engine
**What exists:** Rule-based idle/active/watching/busy state derived from NSEvent monitor, NSWorkspace, and app list.

**Why valuable:** Could gate proactivity (don't interrupt when in a media app, raise urgency when idle). Worth wiring if not already.

### Execution Tracer
**What exists:** `ExecutionTracer.shared` instruments the full pipeline from wake event through TTS finish. 50-trace ring buffer.

**Why valuable:** Essential for debugging voice pipeline latency issues.

---

## Recommended Future Roadmap

### Phase 1 — Stabilise Current Reality (1–2 sprints)
- Fix `RTSPStreamManager.stopAllDetectionLoops()` empty body
- Move API tokens to Keychain (`Keychain.swift` is already there)
- Wire `bargeInSensitivity` to actual threshold in `BargeInMonitor`
- Fix motion zone default feed IDs to use real feed IDs
- Add `NoopWakeWord` detection in watchdog → user-facing "wake word not configured" message
- Implement `BraveSearchProvider` or `DDGProvider`
- Add `privacy: .private` to sensitive log calls

### Phase 2 — Email + Notes (1 sprint)
- Apple Mail via `AppleScriptRunner` — read inbox, compose reply
- VIP + keyword proactivity provider for mail
- Apple Notes create/append via AppleScript

### Phase 3 — Vision Completeness (1–2 sprints)
- Continuous ambient vision (`AmbientVisionService`) with configurable sampling
- Bundle lightweight CoreML model for object detection
- Wire HA camera feeds into POI detection grid
- Fix RTSP stop loop

### Phase 4 — Developer Intelligence Depth (1 sprint)
- Window management via AXUIElement
- GitHub Issues → ProjectKnowledgeService facts injection
- Todoist tasks → ProjectKnowledgeService "what to work on next"

### Phase 5 — Security & Production (ongoing)
- Full Keychain migration for all tokens
- Structured prompt injection markers for LLM context blocks
- Gate screen/camera LLM context behind preference checks
- Memory cap enforcement and cleanup policy
- Test coverage for JarvisController execute() paths

### Phase 6 — Platform Expansion
- Email integration (A2)
- Apple Notes (A12)
- Apple Calendar write-back (currently read-only via EventKit)

### Phase 7 — Advanced Vision
- Face recognition (persistent identity across sessions)
- Cross-camera person tracking
- Home Assistant camera RTSP integration in POI grid

### Phase 8 — Proactivity Intelligence
- ML-based proactivity signal scoring (replace rule-based engine)
- User feedback loop (useful/not-useful trained into suppression model)

### Phase 9 — Gesture Expansion
- Gestures that control macOS UI directly (AXUIElement + accessibility)
- Multi-gesture shortcuts (chord gestures)
- Wrist rotation for overlay resize

### Phase 10 — Multi-Modal Output
- Rich notification cards (not just toast + TTS)
- Timeline event annotation
- Shareable context snapshots
