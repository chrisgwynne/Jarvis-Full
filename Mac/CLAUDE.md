# CLAUDE.md — Jarvis macOS Project Reference

> This file is for Claude (AI assistant). It contains architecture knowledge, patterns, conventions,
> and gotchas to avoid re-learning every session. Keep it updated after every sprint.

---

## Project Overview

**Jarvis** is a macOS voice assistant app (Swift/SwiftUI, macOS 13+). It runs as a status-bar app
with an overlay window system. Voice commands are spoken to a wake word ("Jarvis"), transcribed
locally or via Apple Speech, routed through a phrase matcher + intent router, executed by
`JarvisController`, and responded to via TTS and/or visual overlays.

**Repo:** `/Users/chris/Desktop/jarvis`  
**Scheme:** `JarvisMac`  
**Build:** `make build` (regenerates the project via pinned XcodeGen first). `make test` runs both unit bundles. Full setup + release/notarization steps are in **`BUILD.md`** — read it before touching signing, schemes, or `project.yml`.  
**Language:** Swift 5.9+, SwiftUI, no Combine (uses `@Observable`)  
**Target OS:** macOS 13 Ventura minimum  
**Last sprint commit:** Sprint P9 — Entity Memory + Cross-Device Reference Resolution

**Reference files (always consult before starting new work):**
- `FEATURES.md` — what the app can do today (✅/⚠️/🔲 per feature)
- `TODO.md` — what to build next (full specs, file names, code patterns, effort estimates)
- `CLAUDE.md` — this file (architecture, patterns, gotchas)

---

## Core Data Flow

```
WakeWordService
    ↓ wake event
JarvisController.handleWake()
    ↓
SpeechRecognizer (Apple Speech or Whisper)
    ↓ transcript String
JarvisController.handleTranscript(transcript)
    ↓
CommandPhraseMatcher.match(transcript, against: phraseStore)
    ↓ CommandDefinition.id → IntentMapping → Intent?
    ↓ (fallback if no phrase match)
IntentRouter.route(text:) or route(parsed:)
    ↓ Intent? (.unknown if still unresolved)
    ↓ (fallback to LLM if unknown)
LLMIntentBridge → LLMRouter → MiniMax, Gemini, or llama.cpp
    ↓
JarvisController.execute(intent: Intent)
    ↓
TextToSpeechService.speak(text) + OverlayManager.open(kind:)
```

Follow-up handling: if `activePendingContext != nil`, `FollowUpResolver.resolve()` is checked
BEFORE normal routing and may return a handled intent or defer to LLM.

---

## Key Files Map

### Core
| File | Purpose |
|------|---------|
| `Core/JarvisController.swift` | The orchestrator. ~4000+ lines. Owns ALL services. Wake→STT→intent→execute pipeline. |
| `Core/CommandModels.swift` | `Intent` enum (all cases), `AssistantPhase`, `OperatingMode`, `ListeningSession`, `SafetyLevel` |
| `Core/IntentRouter.swift` | Tier-2 substring routing. `route(parsed:)` for structured parse, `route(_:)` for text. |
| `Core/AppState.swift` | `@Observable` UI state (phase, overlays, toast, diagnostics). Bound to SwiftUI. |
| `Core/ProactivityEngine.swift` | Receives signals, decides speak/show/ignore. Settings struct at top. |
| `Core/ProactivitySignal.swift` | `ProactivitySignal` model, `SignalSource`, `SignalPriority`, `preferredOverlayKind`, provider protocol. |
| `Core/TimerService.swift` | `@Observable @MainActor` multiple named timers + stopwatch. `onTimerExpired` callback. Auto-naming. |

### Phrases / Routing
| File | Purpose |
|------|---------|
| `Phrases/CommandPhraseDefaults.swift` | ~1375 lines. ALL default phrases grouped by category. `all` computed property assembles them. |
| `Phrases/CommandPhraseStore.swift` | `@Observable` persistent store. Seeds from defaults. `mergeNewDefaults()` adds new phrases on upgrade. |
| `Phrases/CommandPhraseMatcher.swift` | Tier-1 phrase matching (exact/prefix/contains). Called before IntentRouter. |
| `Phrases/IntentMapping.swift` | Maps command definition IDs to `Intent` cases. |
| `NLP/CommandUnderstanding.swift` | Parses transcripts into `ParsedCommand` (action + target + label). Fed to `IntentRouter.route(parsed:)`. |
| `NLP/UnmatchedCommandStore.swift` | Stores phrases that produced `.unknown` intent for the "teach me" UI. |

### Responses
| File | Purpose |
|------|---------|
| `Responses/ResponseTemplate.swift` | `ResponseKey` enum — all static string constants like `static let weatherCurrent = "weather.current"` |
| `Responses/ResponsePlaybook.swift` | Default phrase templates for each ResponseKey. Multiple variants per key. |
| `Responses/ResponseTemplateStore.swift` | Persistent user-editable override store. |
| `Responses/ResponseRenderer.swift` | `renderer.render(key, ["var": value])` → final spoken string with variable substitution. |

### Integrations
| File | Purpose |
|------|---------|
| `Integrations/HomeAssistantRESTClient.swift` | HA REST API client. `resolveEntity(matching:)` checks aliases then fuzzy-matches. |
| `Integrations/SmartHomeClient.swift` | Protocol + wrapper for HA client. `aliasStore` wired from JarvisController. |
| `Integrations/HomeEntityAliasStore.swift` | Persistent alias map: spoken name → entity ID. |
| `Integrations/EventKitCalendarService.swift` | EventKit wrapper. `eventsToday()`, `nextEvent()`, `addReminder()`, `spokenSummaryToday()`. |
| `Integrations/TodoistAPIClient.swift` | Todoist REST v2. `getTasks()`, `createTask()`, `closeTask(matching:)`. |
| `Integrations/WeatherService.swift` | WeatherKit. `spokenCurrentWeather()`, `spokenForecast(days:)`, `willItRain(tomorrow:)`. Needs WeatherKit entitlement. |
| `Integrations/CalendarProactivityProvider.swift` | Polls EventKit every 60s. Emits 10-min + 1-min signals. |
| `Integrations/TodoistProactivityProvider.swift` | Polls Todoist every 5min. Morning overdue announcement. |
| `Integrations/GitHubAPIClient.swift` | GitHub REST v3. `getNotifications()`. |
| `Integrations/GitHubProactivityProvider.swift` | Polls GitHub every 10min. Surfaces review requests, mentions, assignments. |
| `Integrations/WeatherProactivityProvider.swift` | Polls every 15min. Morning briefing 7–8am, severe weather urgent, rain warning. |
| `Integrations/HomeAssistantWebSocketClient.swift` | HA WebSocket protocol: auth_required→auth→auth_ok→subscribe_events→state_changed. |
| `Integrations/HomeAssistantProactivityProvider.swift` | Subscribes to `state_changed` events. Alerts: door/lock/motion/smoke/offline/vacuum. |
| `Integrations/ShopifyAPIClient.swift` | Shopify Admin REST 2024-01. `getRecentOrders()`, `getTodayRevenue()`, `getLowStockProducts()`. |
| `Integrations/ShopifyProactivityProvider.swift` | Polls every 5min. New order + low stock signals. |
| `Integrations/SpotifyAPIClient.swift` | Spotify Web API client. Personal token (no OAuth server needed). Full playback control. |
| `Integrations/ObsidianNote.swift` | Model for parsed vault note. YAML frontmatter, inline `#tag`, `[[wikilink]]` parsing. Static regex cache. |
| `Integrations/ObsidianVaultService.swift` | `@MainActor lazy`. Incremental index on 2-min poll. Hybrid FTS+NLEmbedding search. `contextForLLM()` RAG block. `createNote()`/`appendToNote()`. |
| `Integrations/ObsidianProactivityProvider.swift` | 5-min polls. Watch-tag alerts (`obsidianWatchTags`). Recently-modified alerts. `isFirstPoll` seed guard. |

### UI
| File | Purpose |
|------|---------|
| `UI/OverlaySystem.swift` | `OverlayKind` enum (16 kinds), `OverlaySize`, `OverlayManager`. Controls what's shown. |
| `UI/SettingsView.swift` | Tabbed settings. Tabs: General, Voice, AI, Home, Integrations, Personality, Unmatched Commands. |
| `UI/CalendarOverlayView.swift` | Today's event timeline with Now/Soon badges. |
| `UI/TasksOverlayView.swift` | Todoist task list with overdue section. Async load on appear. |
| `UI/UnmatchedCommandsView.swift` | Shows unknown phrases. `TeachCommandSheet` maps to a command. Frequency badge + AI hint. |
| `UI/GitHubOverlayView.swift` | GitHub notifications overlay: Review Requests, Assigned, Mentions, Other. Tap-to-open. |
| `UI/HomeOverlayView.swift` | HA entity grid grouped by room. Tap-to-toggle lights/switches/locks/covers. |
| `UI/ShopifyOverlayView.swift` | Revenue strip + unfulfilled orders + recent orders list. |
| `UI/ObsidianOverlayView.swift` | HSplitView vault browser: search bar, note list (tags, snippet, relative time), note detail (body + wikilink chips via `FlowLayout`), new-note sheet. |
| `UI/DebugHUDView.swift` | Floating HUD with diagnostics — trigger with "developer mode". |

### Memory
| File | Purpose |
|------|---------|
| `Memory/PreferencesStore.swift` | All user preferences. Persisted JSON. API tokens, TTS settings, etc. |
| `Memory/JarvisDatabase.swift` | SQLite via GRDB (or similar). Tables: memories, conversations, snapshots. |
| `Memory/MemoryStore.swift` | CRUD for memories. |
| `Memory/SearchService.swift` | FTS + semantic hybrid search. `hybridSearch(query:limit:)` combines both, deduplicates. |
| `Memory/ConversationSummariser.swift` | LLM-compresses last 20 turns into MemoryStore entries tagged `conversation_summary,auto`. |
| `Memory/SemanticMemoryIndex.swift` | `NLEmbedding.sentenceEmbedding` vector index. Cosine similarity, 500-entry cap. Persisted to `semantic_index.json` (default) or `brain_semantic_index.json` (Brain instance). `init(filename:)` accepts custom filename. |

### Brain
| File | Purpose |
|------|---------|
| `Brain/BrainModels.swift` | All Brain-layer types: `BrainMemorySource`, `BrainPrivacyLevel`, `BrainTaskType`, `BrainTaskStatus`, `BrainTask`, `EpisodeType`, `ConversationEpisode`. SystemBus events: `BrainMemoryWrittenEvent`, `BrainTaskQueuedEvent`, `BrainTaskStatusChangedEvent`, `BrainEpisodeStartedEvent`, `BrainEpisodeEndedEvent`. |
| `Brain/BrainMemoryStore.swift` | Authoritative durable long-term memory. `commit(_:)` (dedup + privacy gate + SQLite + semantic index), `search(query:limit:)` (hybrid FTS5 + semantic), `byType`, `recent`, `delete`, `update`, `pin`, `sweepExpired`, `contextForLLM`. `autoCommitThreshold = 0.49`. |
| `Brain/BrainTaskQueue.swift` | Durable restart-safe task queue. `enqueue`, `markRunning`, `updateProgress`, `complete`, `fail` (auto-retry), `pause`, `cancel`. Prevents duplicate active tasks of same type. Running tasks reset to queued on restore. |
| `Brain/EpisodeStore.swift` | Time-bounded episode grouping. `beginEpisode`, `endEpisode`, `linkMemory`, `linkEntity`, `recordApp`, `recordTopic`. `maybeAutoStart` opens new episode after 30-min idle gap. `todaysSummary()`, `weekSummary()`, `search(query:)`. |
| `Brain/BrainRuntime.swift` | `RuntimeSubsystem` (startupOrder=25). Opens own `JarvisDatabase` connection, creates `SemanticMemoryIndex(filename:"brain_semantic_index.json")`, configures all three stores, kicks off `sweepExpired` on start. Health: degraded if db nil. |

**Brain ownership model:**
- `ConversationMemoryStore` — short-term conversational staging (200 turns, 500 candidates)
- `MemoryStore` — explicit user "remember this" entries
- `BrainMemoryStore` — committed, searchable, governed long-term intelligence (authoritative)
- `EpisodeStore` — timeline/session grouping
- `BrainTaskQueue` — durable orchestration

**Brain memory lifecycle:**
```
RAW EVENT → MemoryExtractor → MemoryCandidate (staged in ConversationMemoryStore) →
importance/confidence scoring → commit(_:) (if score ≥ autoCommitThreshold 0.49) →
BrainMemoryStore (SQLite brain_memories table) + SemanticMemoryIndex (brain_semantic_index.json) →
EpisodeStore grouping → dream-cycle consolidation (Phase 2+)
```

**Brain performance rules:** Brain systems must NEVER block conversation flow, stall UI, increase audio latency, freeze overlays, or delay wake-word response. All heavy work goes on detached Tasks at `.utility` priority.

**Brain privacy rules:** No hidden memory writes. Every memory must be inspectable, editable, deletable, traceable. Privacy filtering BEFORE persistence. Private memories only stored if source is `.voiceCommand` or `.userEdited`.

**pbxproj prefix:** `BN` (Brain group: `BN00A2B3C4D5E6F7A8B9CGRP`, build files `BN01...0001–0005`, file refs `BN02...0001–0005`).

### Audio
| File | Purpose |
|------|---------|
| `Audio/TextToSpeechService.swift` | Protocol + routing between Apple AVSpeech and Piper TTS. |
| `Audio/PiperTTS.swift` | Local TTS engine. Needs Piper executable + ONNX model path. |
| `Audio/SpeechRecognizer.swift` | Protocol + routing between Apple Speech and Whisper. |
| `Audio/WakeWordService.swift` | Protocol + routing between Apple and Sherpa wake word. |

---

## Patterns & Conventions

### Adding a new voice command — full checklist

1. **`CommandModels.swift`** — add `case newIntent` or `case newIntent(param: Type)` to `Intent` enum
2. **`CommandPhraseDefaults.swift`** — add `def("command_id", "Display Name", .category, "Description.", .priority, [("phrase", .exact), ...])` to the appropriate static var, and include it in `all`
3. **`IntentMapping.swift`** — add `"command_id": .newIntent` mapping (if using phrase store routing)
4. **`IntentRouter.swift`** — add substring routing in `route(_ text:)` as a fallback
5. **`ResponseTemplate.swift`** — add `static let newKey = "category.new_key"` to `ResponseKey`
6. **`ResponsePlaybook.swift`** — add `add(ResponseKey.newKey, ["Phrase with {var}.", "Alternative phrase."])`
7. **`JarvisController.swift`** — add `case .newIntent: speak(renderer.render(ResponseKey.newKey, ["var": value]))` in the `execute()` switch
8. **`project.pbxproj`** — if adding new files, add PBXBuildFile + PBXFileReference + group membership + Sources build phase entry

### ResponseKey pattern
```swift
// In ResponseTemplate.swift
static let myKey = "category.my_key"

// In ResponsePlaybook.swift (inside the build() method)
add(ResponseKey.myKey, [
    "Primary phrase with {variable}.",
    "Alternative with {variable}.",
])

// In JarvisController.swift
speak(renderer.render(ResponseKey.myKey, ["variable": someValue]))
```

### CommandPhraseDefaults `def()` helper
```swift
def("command_id",           // stable string ID
    "Display Name",          // shown in Settings
    .category,               // CommandCategory enum case
    "What this command does.", // tooltip description
    .low,                    // CommandPriority (.low / .medium / .high)
    [
        ("what the user says", .exact),    // exact match after normalization
        ("prefix match",       .prefix),   // user's phrase starts with this
        ("substring",          .contains), // user's phrase contains this
    ]
)
```

### Adding a new proactivity provider
1. Create `Integrations/XxxProactivityProvider.swift` conforming to `ProactivitySignalProvider`
2. Implement `start()` (begin polling Task), `stop()` (cancel task), `pollNow()` (fetch + emit signals)
3. Emit signals via `engine.ingest(signal, appState: appState)` — engine handles dedup/cooldown/quiet hours
4. Add per-source enable flag to `ProactivitySettings` in `ProactivityEngine.swift`
5. Add gate in `decide()` method of `ProactivityEngine`
6. Instantiate and `start()` from `JarvisController` configure section
7. Store as `private var` on JarvisController (prevents deallocation)
8. Add to `project.pbxproj`

### Adding a new overlay
1. Create `UI/XxxOverlayView.swift`
2. Add case to `OverlayKind` enum in `OverlaySystem.swift` — fill in `title`, `systemImage`, `defaultSize`, `accentColor`, add to `isImplemented` list
3. Wire the view in `OverlaySystem.swift` `standardContent` switch
4. Add `Intent` case e.g. `showXxxOverlay`
5. Add phrases in `CommandPhraseDefaults`
6. Add ResponseKey + template
7. Handle in `JarvisController.execute()` with `openOverlay(.xxx)` + `speak(...)`
8. Add to `pbxproj`
9. Update `ProactivitySignal.preferredOverlayKind` if a signal source should open this overlay

---

## pbxproj UUID Convention

When manually adding files to the Xcode project, use the pattern:
- `XX01A2B3C4D5E6F7A8B9CxYz` for PBXBuildFile (the "in Sources" entry)
- `XX02A2B3C4D5E6F7A8B9CxYz` for PBXFileReference (the actual file)

Where `XX` is a 2-letter prefix for the feature. Existing prefixes:
- `EC` — EventKitCalendarService
- `TD` — TodoistAPIClient
- `WE` — WeatherService
- `CP` — CalendarProactivityProvider
- `TP` — TodoistProactivityProvider
- `GH` — GitHubAPIClient
- `GP` — GitHubProactivityProvider
- `CO` — CalendarOverlayView
- `TO` — TasksOverlayView
- `HA` — HomeEntityAliasStore
- `UM` — UnmatchedCommandsView
- `HW` — HomeAssistantWebSocketClient
- `HP` — HomeAssistantProactivityProvider
- `HO` — HomeOverlayView
- `SA` — ShopifyAPIClient
- `SH` — ShopifyProactivityProvider
- `SO` — ShopifyOverlayView
- `SP` — SpotifyAPIClient
- `OV` — ObsidianNote / ObsidianVaultService / ObsidianProactivityProvider / ObsidianOverlayView
- `TS` — TimerService
- `CS` — ConversationSummariser
- `SM` — SemanticMemoryIndex
- `SB` — SystemBus / SystemEventTypes
- `MB` — Ambient group (AmbientContextEngine, ActiveAppMonitor, WindowContextMonitor, AmbientContextModels, PrivacyFilter, AmbientContextOverlayView)
- `HB` — MacBrain group (BrainAPIModels, BrainDiagnostics, MacBrainServer, BrainHTTPHandler, BrainContextEngine, all providers, all stores, MacBrainSettingsView, MacBrainServerTests)
- `MC` — MacBridge group (MacCameraService, MacCameraFrameStore, MacCameraDiagnostics, MacCameraHttpRoutes, MacCameraSettingsView, MacCameraServerTests)
- `LN` — LocalLearning group (LocalLLMConfig, InteractionRecorder, CorrectionDetector, LearnedCommandAliasStore, FailedUtteranceStore, UserCorrectionStore, SuccessfulRouteStore, LocalConversationMemoryStore, TrainingExampleStore, LocalLLMClient, LocalLearningEngine, TrainingDataView)
- `PL` — ConversationalPivotPlanner (Sprint N)
- `SE` — StreamingConversationEngine (Sprint N)
- `ES` / `MI` / `MR` / `MW` — EpisodicMemoryStore, MemoryImportanceScoring, EpisodicMemoryRetriever, MemoryConsolidationWorker (Sprint N)
- `PC` / `SD` / `VN` — PersistentVisionContext, SceneChangeDetector, VisionStateSummary (Sprint N)
- `BP` / `PS` / `RM` — BehaviourPatternEngine, PredictiveSuggestionEngine, ReminderEscalationModel (Sprint N)
- `JR` / `RZ` / `SN` — JarvisRuntimeCoordinator, RuntimeReasoningLayer, SprintNTests (Sprint N)
- `LB` — LatencyBudgetSystem (Sprint O)
- `PN` — ProactivityNoiseController (Sprint O)
- `RD` — RuntimeHealthDedup (Sprint O)
- `QR` — BehaviourScenarioRunner (Sprint O)
- `MV` — MemoryValidationLayer (Sprint O)
- `SL` — StreamingRecoveryLayer (Sprint O)
- `VF` — VisionEfficiencyController (Sprint O)
- `OT` — SprintOTests (Sprint O)
- `TG` — ToolExecutionGraph (Sprint Q)
- `PT` — PostToolContextInjection (Sprint Q)
- `VP` — VisionActionPipeline (Sprint Q)
- `TR` — PostToolReasoningTests (Sprint Q)
- `DB` — DistributedBrain group (Sprint P7); file prefixes: DM, DC, PA, DO, SK, DR, RX, GC, DF, BV, AC, DD, DT
- `GL` — GlobalPresenceState (Sprint P8)
- `XE` — EntityMemory group (Sprint P9); file prefixes: XM, ZE, XX, ZH, XS, XL, XW, XD, XB, XY, XT
- `EL` — EntityModels (Sprint R)
- `MD` — MediaEntityDatabase (Sprint R)
- `EF` — EntityFirstResolver (Sprint R)
- `EG` — EntityProviders (Sprint R)
- `EI` — EntityIntentBinder (Sprint R)
- `CE` — CustomEntityAliasStore (Sprint R)
- `ER` — EntityFirstResolverTests (Sprint R)

---

## Preferences & API Tokens

All stored in `Preferences` struct, persisted to `~/Library/Application Support/JarvisMac/preferences.json`.

| Field | Purpose |
|-------|---------|
| `userName` | User's name for identity queries |
| `smartHomeBaseURL` | HA base URL e.g. `http://192.168.1.20:8123` |
| `smartHomeToken` | HA long-lived access token |
| `todoistAPIToken` | Todoist REST v2 bearer token |
| `githubPersonalAccessToken` | GitHub PAT with `notifications` scope |
| `ttsEngine` | `.appleSystem` or `.piper` |
| `ttsVoiceIdentifier` | AVSpeechSynthesisVoice identifier |
| `ttsRate` / `ttsPitch` | TTS speed and pitch |
| `speechEngine` | `.apple` or `.whisper` |
| `whisperModelPath` | Path to local Whisper GGUF model |
| `bargeInEnabled` | Whether wake word during TTS cancels speech |
| `conversationalFollowUpEnabled` | Whether follow-up resolver is active |
| `miniMaxEnabled` / `miniMaxBaseURL` | MiniMax LLM config |
| `llamaCppEnabled` / `llamaCppBaseURL` / `llamaCppModel` | llama.cpp local LLM config (default port 8080) |
| `shopifyAccessToken` | Shopify Admin API access token (private app) |
| `shopifyShopDomain` | Shop domain e.g. `mystore.myshopify.com` |
| `shopifyLowStockThreshold` | Inventory threshold for low-stock alerts (default: 5) |
| `spotifyPersonalToken` | Spotify personal access token (OAuth Playground) — scopes: `user-read-playback-state user-modify-playback-state` |
| `obsidianVaultPath` | Absolute path to the Obsidian vault folder (e.g. `/Users/chris/Documents/MyVault`) |
| `obsidianLLMContextEnabled` | Whether vault notes are injected as RAG context into every LLM call (default: true) |
| `obsidianMaxContextNotes` | Max number of notes injected per LLM query (default: 3, range 1-8) |
| `obsidianProactivityEnabled` | Whether `ObsidianProactivityProvider` is active (default: true) |
| `obsidianWatchTags` | Tags that trigger watch alerts — `["jarvis", "review", "urgent"]` by default |

To add a new preference:
1. Add field to `Preferences` struct with default value
2. Add `CodingKey` case
3. Add `decode` line in `init(from:)` using `decodeIfPresent` with fallback

---

## Build Gotchas

### xcodebuild path
```bash
# Use full path — system xcode-select may point to CLT:
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme JarvisMac -configuration Debug build
```

### SwiftUI ViewBuilder 10-child limit
`TabView` / `Group` bodies can't have more than 10 direct children. Split into `Group {}` blocks when adding tabs.

### @Observable + @MainActor
All store/service classes are `@MainActor final class`. Accessing them from async contexts needs `await MainActor.run { ... }`. In `nonisolated` delegate callbacks, use `Task { @MainActor in ... }`.

### WeatherKit
Requires the WeatherKit **capability** added in Xcode (not just the framework). Without it, all calls silently fail. `WeatherService.isAuthorized` will be false until location is granted AND the entitlement is present.

### CommandPhraseStore.mergeNewDefaults()
When new phrases are added to `CommandPhraseDefaults` for EXISTING commands, existing users won't get them until `mergeNewDefaults()` runs at startup. This is now implemented (Step 2 in the method merges new phrases into existing definitions). Don't skip it when adding phrases to existing command IDs.

### Camera "what do you see" routing
The `describe_camera` command needs its phrases to be in the phrase store. If a user installed before these phrases were added, `mergeNewDefaults()` will inject them. The IntentRouter also has a broad substring fallback for `whatCanYouSee` as belt-and-suspenders.

---

## ProactivityEngine API

```swift
// Ingest a signal (thread-safe, @MainActor)
engine.ingest(signal, appState: appState)

// Query state
engine.pendingSignals          // [ProactivitySignal] in tray
engine.lastSpokenSignal        // most recently announced signal
engine.latestPresentation      // ProactivityPresentation? for "open that"
engine.isPaused                // Bool

// Control
engine.pause()
engine.resume()
engine.dismiss(signalId)
engine.dismissAll()
engine.mute(.news, for: 3600)  // mute source for N seconds
engine.unmute(.news)
engine.settings.calendarEnabled = false  // per-source toggle
```

---

## Persistent Conversation Session — Invariants

After one wake-word trigger, Jarvis listens **indefinitely** (up to 10 minutes of inactivity).
These are the only events that permanently end the session:

| Event | Handler | Effect |
|-------|---------|--------|
| User says "stop listening" / "go quiet" | `disableListening()` | Clears `conversationalArmed`, goes muted |
| App closes / emergency stop | `forceEmergencyStop()` | Clears both flags, all tasks cancelled |
| Microphone ownership failure | `permanentSpeechFailureActive` guard | Returns to passive wake, not conversational |
| 10-minute inactivity | `conversationalArmTask` sleep | Clears `conversationalArmed` + `conversationalSessionActive` |

**These must NOT end the session** (silence, overlays, TTS finishing, unknown commands):
- `stopListening()` — does NOT clear `conversationalSessionActive`
- Barge-in on wake word — does NOT clear `conversationalSessionActive`
- `stopSpeaking()` ("stop talking") — does NOT clear session; restarts STT if armed
- `endConversationalSession(permanent: false)` — restarts STT after 150ms if armed

**Key variables:**
- `conversationalArmed` (private, JarvisController) — the 10-minute window flag
- `conversationalSessionActive` (private, JarvisController) — true while session live
- `lastSpeakCalledAt: Date` — set synchronously in `speak()`, used in post-loop to detect pending TTS within 0.5s window so non-TTS commands (overlays) restart STT correctly
- `prefs.current.persistentConversationEnabled` — master switch (default true)

**Restart paths (priority order):**
1. `execute()` defer → `startConversationalListening()` (immediate, for most commands)
2. `rewireSpeakingObserver` post-TTS → `startConversationalListening()` (after TTS ends)
3. `endConversationalSession(permanent:false)` → 150ms Task restart (after silence timeout)
4. Post-loop → 150ms Task restart (after STT ends, no TTS pending, armed)
5. `wakeWatchdogTick()` → `startConversationalListening()` (1s repair, race catch)

---

## FollowUpResolver

Used for conversational follow-ups. When Jarvis asks a yes/no question, set:
```swift
activePendingContext = PendingConversationContext(
    question: "Do you want me to turn off the lights?",
    expectedResponseType: .yesNo,
    onYes: .executeIntent(.homeTurnOff(entity: "all lights")),
    onNo: .speak("OK, leaving them on.")
)
```

The next transcript runs through `FollowUpResolver.resolve()` before normal routing.
Clear `activePendingContext` after resolution. A 10-second timeout auto-clears it.

---

## Overlay System

```swift
// Open an overlay
openOverlay(.calendar)           // from JarvisController
overlayManager.open(.tasks)      // direct

// Close
closeOverlay()
overlayManager.closeTopOverlay()

// Resize
resizeOverlay(to: .large)
```

Overlay kinds and their views:
| Kind | View | Size |
|------|------|------|
| `.news` | `NewsOverlayView` | large |
| `.camera` | `CameraPreviewWidget` / cinematic | cinema |
| `.calendar` | `CalendarOverlayView` | large |
| `.tasks` | `TasksOverlayView` | large |
| `.memory` | memory browser | medium |
| `.chat` | `ChatOverlayView` | large |
| `.timeline` | `TimelineOverlayView` | large |
| `.notifications` | `NotificationTrayView` | medium |
| `.article` | WKWebView | large |
| `.screen` | screen awareness | medium |
| `.reasoning` | reasoning trace | medium |
| `.test` | debug status | compact |
| `.proactiveAlert` | generic alert card | compact |
| `.home` | `HomeOverlayView` | large |
| `.shopify` | `ShopifyOverlayView` | large |
| `.github` | `GitHubOverlayView` | large |

---

## Sprint History

| Commit | Sprint | Key features |
|--------|--------|-------------|
| `550a51a` | Phase 1 | MVP: wake word, STT, basic intents, TTS |
| `862f61d` | Phase 1.5 | Sherpa ONNX wake word |
| `453fe10` | Phase 2 | Whisper STT, vision, context, latency tracking |
| `538bea7` | Phase 2.5 | Stabilisation |
| `79168a4` | PR merge | — |
| `ace3bfb` | Sprint A | HA extended (brightness/color/scenes/covers/locks), Calendar (EventKit), Todoist, ResponseRenderer audit, camera routing fix, ProactivityEngine, News system, LLM layer, Memory, Personalities, ~50 new response keys |
| `300302d` | Sprint B | Weather (WeatherKit), Proactivity providers (Calendar/Todoist/GitHub), CalendarOverlayView, TasksOverlayView, HomeEntityAliasStore, UnmatchedCommandsView, Settings enhancements (GitHub/Todoist/proactivity toggles/HA aliases), Help command, Daily briefing |
| `fc9e84f` | Sprint B docs | FEATURES.md (app capability tracker), CLAUDE.md (AI reference), TODO.md (gap analysis — 15 not-started + 12 partially-built items with full implementation specs) |
| `552a582` | Sprint C | All 12 Section B items: multi-turn conversations (.choice type), memory→LLM injection, streaming partial early-exit, WeatherProactivityProvider, personality depth (buildSystemPrompt wired), wake watchdog, dual camera (CameraRole), pinnable overlays, GitHubOverlayView, Wi-Fi/BT toggles, HA automations by voice, unmatched command frequency+LLM learning |
| `9547091` | Sprint D | A1 HA WebSocket proactivity (door/lock/motion/smoke/vacuum), A3 Shopify (API+overlay+proactivity), A4 HomeOverlayView (room-grouped entity grid), A8 TimerService (multi named timers+stopwatch), A9 clipboard (NSPasteboard read/write), A10 SpotifyAPIClient (personal token playback control), A14 ConversationSummariser (LLM→MemoryStore), A15 SemanticMemoryIndex (NLEmbedding cosine search + hybridSearch) |
| `bf89376` | Audit patches | 15-section codebase audit: P0 ShopifyOverlay wiring, HA door/lock timer fix, Shopify isFirstPoll guard, openURL scheme allowlist, NoopWakeWord watchdog fix, speakText length cap, preferences.json 0o600/0o700 permissions, 18 missing IntentMapping entries, "stop speaking" routing, WiFi/BT toggle routing, WS invalidateAndCancel + ping/pong, announcedKeys cap, NSDataDetector static cache, ProactivityEngine exhaustive switch |
| `1fefcba` | Sprint E | Obsidian vault integration: ObsidianNote model (frontmatter/tags/wikilinks), ObsidianVaultService (incremental index, FTS+NLEmbedding hybrid, RAG injection, create/append), ObsidianProactivityProvider (watch-tags, recently-modified, isFirstPoll), ObsidianOverlayView (HSplitView browser, FlowLayout wikilinks), 9 new intents, Settings Obsidian tab, all wired into JarvisController |
| *(unpushed)* | Listening lifecycle fix | P0 persistent-conversation regression: removed `conversationalSessionActive=false` from stopListening/barge-in/stopSpeaking; rewrote `endConversationalSession(permanent:)` to restart STT on silence timeout; fixed post-loop to restart STT for non-TTS commands; added conversational watchdog in `wakeWatchdogTick`; added `persistentConversationEnabled` pref; added `lastSpeakCalledAt` synchronous TTS sentinel; AppState diagnostic fields `conversationalArmedDiag/persistentSessionActive/conversationalRestarts`. Camera routing fix: Step 3 in `mergeNewDefaults()` re-normalizes stored phrases; key camera phrases widened to `.contains`. |
| *(unpushed)* | Sprint F | SystemBus + AmbientContextEngine foundation — see Sprint F feature notes below |
| *(unpushed)* | Sprint G | RuntimeCoordinator architecture — see Sprint G feature notes below |
| *(unpushed)* | Sprint H | Event-driven migration + runtime extraction pass — see Sprint H feature notes below |
| *(unpushed)* | Brain Phase 1 | Brain layer foundation — see Brain Phase 1 notes below |
| *(unpushed)* | Brain Phase 2 | Signal wiring — see Brain Phase 2 notes below |
| *(unpushed)* | Sprint P (Brain 3-5) | LLM context injection, Brain Governance UI, BrainDreamCycle — see Sprint P notes below |
| *(unpushed)* | Sprint U | ContextGraph persistence, enrichment, prune — see Sprint U feature notes below |
| `350a5e8` | Sprint V | Relationship Reasoning + Context Ranking — see Sprint V feature notes below |
| `6d1e703` | Sprint W | Focus Awareness Commands + Context Explainability — see Sprint W feature notes below |
| `9f17e39` | Sprint X | Apple Notes Quick-Capture + Context Graph ingestion — see Sprint X feature notes below |
| *(unpushed)* | Sprint AA | Apple Mail integration (AppleMailService, EmailIntentHandler, EmailProactivityProvider) |
| *(unpushed)* | Sprint AB | Mac Brain HTTP Service — local JSON API for Android Jarvis — see Sprint AB feature notes below |
| *(unpushed)* | Sprint AC | Mac Camera HTTP Server — webcam snapshot + MJPEG streaming on port 8765 — see Sprint AC feature notes below |
| `f672cb9` | Sprint AD | JarvisLocalLearningEngine — local LLM pre-routing, 7 learning stores, correction detection, JSONL export, Training Data UI — see Sprint AD feature notes below |
| `80cfb8e` | Sprint L | Conversational OS foundation — see Sprint L feature notes below |
| `9890ead` | Sprint M Ph1 | Provider → orchestrator migration (all 8 providers) — see Sprint M feature notes |
| `a22e541` | Sprint M Ph2 | ConversationalTimingEngine, AmbientWorldState, RuntimeHealthMonitor — see Sprint M feature notes |
| `532334c` | Sprint N | Streaming Interruption + Episodic Memory + Passive Vision + Predictive Assistance + Runtime Coordination — see Sprint N feature notes |
| `0e9f234` | Sprint N wiring | All 10 deferred Sprint N call-site integrations wired into JarvisController + BrainRuntime |
| `013eb77` | Sprint O | Behaviour Verification + Hardening + QA — see Sprint O feature notes below |
| `f7c986e` | Sprint Q | Post-tool conversational continuation + vision action chaining — see Sprint Q feature notes below |
| `c1c4444` | Sprint R | Entity-First Resolver — semantic media/app/HA entity resolution — see Sprint R feature notes below |
| `7a596be` | Sprint P7 | Distributed Brain + Windows Sidecar Orchestration (13 new files, SSE-based) |
| `e5a3ec3` | Sprint P8 | WebSocket MacBridgeProtocolV2 + GlobalPresenceState — see Sprint P8 feature notes below |
| *(unpushed)* | Sprint P9 | Entity Memory + Cross-Device Reference Resolution — see Sprint P9 feature notes below |

---

## Planned Next Sprints (see TODO.md for full specs, FEATURES.md §24 for full list)

### Immediate (next sprint)
1. **A6 — Continuous ambient vision** — `AmbientVisionService`, background camera frame analysis, event-driven.

### Completed this session
- **A2 — Apple Mail** ✅ — `AppleMailService` + `EmailIntentHandler` + `EmailProactivityProvider` (Sprint AA).
- **Mac Brain HTTP Service** ✅ — NWListener JSON API on port 8765 for Android Jarvis (Sprint AB).
- **A12 — Apple Notes** ✅ — `AppleNotesService` + `NotesIntentHandler` + ContextGraph ingestion (Sprint X).
- **Mac Camera HTTP Server** ✅ — `/camera/health` + `/camera/snapshot` + `/camera/stream` (MJPEG) on port 8765 (Sprint AC).

### Remaining audit items (P1–P2, deferred)
- Move 5 API tokens (HA, Todoist, GitHub, Shopify, Spotify) from preferences.json to macOS Keychain
- Add prompt injection structural markers `[MEMORY CONTEXT]` before LLM injection in tryLLMFallback
- Gate screen/camera LLM context behind `llmSendsScreenContext`/`llmSendsCameraContext` prefs
- Change `requireWebSocketAuth` default to `true` in Preferences
- Add `privacy: .private` annotation to ConversationSummariser log call
- Fix `show_calendar_overlay`/`show_tasks_overlay` duplicate exact phrase priority conflicts
- Make timer regex patterns in IntentRouter `static let` (currently compiled per-call)
- Fix `shopifyStatus` recursive `execute()` call (JarvisController.swift ~line 3022)

### Future
3. **A6 — Continuous ambient vision** — `AmbientVisionService`, background camera frame analysis, event-driven.
4. **A11 — Window management** — `AXUIElement` position/size, tiling, multi-display.
5. **A5 — Gesture control** — `VNDetectHumanHandPoseRequest`, pinch/palm/point gestures.
6. **A7 — Unified fullscreen stage** — transparent `NSWindow` layer owning the screen.

### Sprint C feature notes (all B items complete — see Sprint D notes below)
- **Multi-turn** ✅ — `.choice` follow-up type added. `homeTurnOn/Off`, `addTask`, `addReminder` now trigger disambiguation when entity/text is empty. `FollowUpResolver` handles `.choice` with fuzzy match + re-ask.
- **Memory→LLM** ✅ — `tryLLMFallback` now fetches top-3 relevant memories and appends to system prompt.
- **Personality** ✅ — `PersonalityContextBuilder.buildSystemPrompt()` now generates structured preamble (name, honorific, formality, humour) injected into every LLM call.
- **Streaming partials** ✅ — `FastResponseRouter` runs on every 3+ word partial; confidence ≥0.92 → early STT exit. `handledByPartial` flag prevents double-execution.
- **Wake watchdog** ✅ — 60s polling loop in `JarvisController`. Cancelled/restarted on `rebuildWakeWord()`.
- **Dual camera** ✅ — `CameraManager` now `CameraRole`-based (`.primary`/`.secondary`). `deskCameraUID` preference + Settings picker.
- **Pinnable overlays** ✅ — `isPinned` on `OverlayState`. `closeTop()` skips pinned. Pin button in title bar. `pinOverlay`/`unpinOverlay` intents.
- **GitHub overlay** ✅ — `GitHubOverlayView.swift` with 4 sections. `.github` `OverlayKind`. `checkGitHub`/`showGitHubOverlay` intents.
- **Wi-Fi/BT** ⚠️ — `setWifi(on:)` via `networksetup` CLI. `setBluetooth(on:)` via `blueutil` (requires `brew install blueutil`) or System Settings fallback.
- **HA automations** ✅ — `homeRunAutomation(name:)` intent. Resolves entity then calls `automation.trigger`.
- **Unmatched learning** ✅ — frequency dedup, `llmResolvedIntent` stored after LLM resolution, UI shows ×N badge + "AI resolved" hint.

### Sprint D feature notes
- **HA WebSocket proactivity** ✅ — `HomeAssistantWebSocketClient` + `HomeAssistantProactivityProvider`. Subscribes to `state_changed`. Door/lock/motion/smoke/offline/vacuum alerts. Smoke/CO bypass quiet hours.
- **Shopify** ✅ — `ShopifyAPIClient` + `ShopifyProactivityProvider` + `ShopifyOverlayView`. New order + low-stock signals. Voice: orders/revenue/fulfilment/status. Settings: token + domain + threshold + proactivity toggle.
- **Home overlay** ✅ — `HomeOverlayView` room-grouped entity grid. Tap-to-toggle. `.homeAssistant → .home` in `preferredOverlayKind`. Triggers: "home panel", "show devices".
- **Timers** ✅ — `TimerService` with multiple named timers + stopwatch. Auto-naming ("Timer 1", "Timer 2"). Expiry fires `.system` `.urgent` ProactivitySignal + TTS.
- **Clipboard** ✅ — `readClipboard()` / `writeClipboard()` via `NSPasteboard` in `MacSystemController`. `clipboardRead`/`clipboardCopy` intents.
- **Spotify** ✅ — `SpotifyAPIClient` using personal token (no OAuth server). Play/pause/next/previous/shuffle/volume/what's playing. Settings: Spotify token field.
- **Conversation summaries** ✅ — `ConversationSummariser`. LLM-compresses last 20 turns. No-ops if <4 turns / LLM disabled / already summarised. Fires on session end + daily.
- **Semantic memory** ✅ — `SemanticMemoryIndex` using `NLEmbedding.sentenceEmbedding(for: .english)`. Cosine similarity. 500-entry cap. Persisted JSON. `hybridSearch` in `SearchService` combines FTS + semantic.

### Sprint F feature notes
- **SystemBus** ✅ — `Core/SystemBus.swift`. `@MainActor final class`. Generic typed pub/sub: `subscribe<E: SystemEvent>(_ type:handler:) -> SubscriptionToken`, `unsubscribe(_ token:)`, `publish<E: SystemEvent>(_ event:)`. Ring buffer of 200 recent events. No Combine, no framework — synchronous dispatch on MainActor. `SystemEventSource`, `SystemEventCategory`, `SystemEventPriority` enums.
- **SystemEventTypes** ✅ — `Core/SystemEventTypes.swift`. 16 concrete event structs conforming to `SystemEvent`: `AppFocusChangedEvent`, `AppLaunchedEvent`, `AppClosedEvent`, `ScreenContextUpdatedEvent`, `ScreenErrorDetectedEvent`, `ContextRedactedEvent`, `OverlayOpenedEvent`, `OverlayClosedEvent`, `SpeechCommandReceivedEvent`, `SpeechFollowUpReceivedEvent`, `MemoryUpdatedEvent`, `ProactiveSignalGeneratedEvent`, `AndroidConnectedEvent`, `AndroidDisconnectedEvent`, `GitHubBuildFailedEvent`, `SystemLowMemoryEvent`, `SystemAudioErrorEvent`.
- **AmbientContextEngine** ✅ — `Ambient/AmbientContextEngine.swift`. `@MainActor final class`. Passive awareness: tracks active app (via `ActiveAppMonitor`), window titles (via `WindowContextMonitor`), optional screen sampling at 30s normal / 8s watch mode. Privacy-gated. Emits `AppFocusChangedEvent`, `ScreenContextUpdatedEvent`, `ScreenErrorDetectedEvent`, `ContextRedactedEvent` to SystemBus. Feeds `ContextEngine.setActiveApp()` and `contextEngine.recordScreen()`. Wire: `ambientContext.screenAwareness`, `ambientContext.contextEngine`, `ambientContext.setEnabled(prefs.current.ambientModeEnabled)`.
- **ActiveAppMonitor** ✅ — `Ambient/ActiveAppMonitor.swift`. `@MainActor`. NSWorkspace `didActivateApplicationNotification` + `didLaunchApplicationNotification` + `didTerminateApplicationNotification`. CGWindowListCopyWindowInfo for permission-free window titles. Publishes `AppFocusChangedEvent`, `AppLaunchedEvent`, `AppClosedEvent`. Suppresses duplicate events (same bundleID + windowTitle).
- **WindowContextMonitor** ✅ — `Ambient/WindowContextMonitor.swift`. Polls at 5s (configurable). CGWindowListCopyWindowInfo for window title. `onWindowChanged` callback.
- **AmbientContextModels** ✅ — `Ambient/AmbientContextModels.swift`. `ActiveApp`, `ScreenContextSummary` (richer than `ScreenSummary` — includes `detectedTask`, `visibleEntities`, `visibleErrors`, `confidence`, `isRedacted`), `WatchModeState` enum (`.inactive` / `.active(startedAt:expiresAt:targetApp:)`), `AmbientContext` (full current picture, `contextDescription` for LLM injection).
- **PrivacyFilter** ✅ — `Ambient/PrivacyFilter.swift`. Blocks password managers (1Password, Bitwarden, Keychain), private browsing windows (Safari/Chrome incognito). Configurable `additionalBlockedBundleIDs` / `additionalBlockedNames`. Returns `isBlocked(bundleID:appName:windowTitle:)`. Blocked apps emit `ContextRedactedEvent`, no screenshot/OCR.
- **Watch mode** ✅ — `ambientContext.activateWatchMode(duration:targetApp:)` boosts sampling to 8s for the specified app. Auto-expires via Task sleep. `watchThis` / `stopWatching` intents wired.
- **AmbientContextOverlayView** ✅ — `UI/AmbientContextOverlayView.swift`. Debug overlay (`.ambientContext` OverlayKind, `.compact`). Shows active app, window title, latest semantic summary, errors, watch mode state, recent SystemBus events with colour-coded categories.
- **Event wiring** ✅ — `OverlayManager.open()` + `close()` publish `OverlayOpenedEvent`/`OverlayClosedEvent`. `JarvisController` subscribes `ScreenErrorDetectedEvent` → ProactivitySignal injection. `ContextEngine.setActiveApp()` added.
- **New intents** ✅ — `whatAmIWorkingOn`, `whatFailedOnScreen`, `whatChangedOnScreen`, `watchThis`, `stopWatching`, `enableAmbientContext`, `disableAmbientContext`, `showAmbientContextOverlay`. All wired in IntentRouter, IntentMapping, CommandPhraseDefaults, ResponseTemplate/Playbook, JarvisController.execute().
- **pbxproj prefixes** — `SB` (SystemBus, SystemEventTypes), `MB` (Ambient group + 5 Ambient files + overlay).

### Sprint E feature notes
- **Obsidian vault** ✅ — `ObsidianNote` parses `.md` files: strips `---` YAML frontmatter, extracts `#tags` (inline + frontmatter list), `[[wikilinks]]`. Static cached regexes.
- **ObsidianVaultService** ✅ — `lazy` property on JarvisController. 2-minute incremental index poll (only re-embeds new/changed notes). `hybridSearch(query:limit:)` = async semantic + sync FTS deduplicated. `contextForLLM()` returns `[OBSIDIAN VAULT CONTEXT]` block injected into every LLM fallback. `createNote(title:content:)` writes frontmatter with `source: jarvis`. `appendToNote(matching:text:)` appends timestamped block.
- **ObsidianProactivityProvider** ✅ — `isFirstPoll` seeds `seenModifiedDates` silently. Watch-tag alerts: fires once per note gaining a `obsidianWatchTags` tag (default: `jarvis`, `review`, `urgent`). Recent-modification alerts for externally-changed notes. 5-minute poll.
- **ObsidianOverlayView** ✅ — `HSplitView` with 240–340pt note list + detail pane. Note rows: title, 2-line snippet, relative modified time, up to 4 `#tag` capsules. Detail: selectable body text, wikilink chips in `FlowLayout` (custom wrapping `Layout`). New-note sheet with title + content. 3-second auto-dismiss status strip.
- **RAG injection** ✅ — In `tryLLMFallback`, after memory block: `obsidianVault.contextForLLM(query:maxNotes:maxCharsPerNote:600)` appended to `ctx`. Gated by `obsidianLLMContextEnabled` pref.
- **Settings** ✅ — New "Obsidian" tab between Integrations and Responses: vault folder picker (NSOpenPanel, directory-only), note count badge, LLM context toggle + max-notes stepper (1-8), proactivity toggle + watch-tags text field, re-index button.

### Sprint F feature notes
- **SystemBus** ✅ — `@MainActor final class SystemBus`. Typed pub/sub via `subscribe<E: SystemEvent>`, `publish<E>`, `unsubscribe(token:)`. 200-event ring buffer. `subscribeAll` for catch-all subscribers (used by EventStore). `SystemEventSource/Category/Priority` enums.
- **SystemEventTypes** ✅ — 16 concrete event structs: `AppFocusChangedEvent`, `ScreenContextUpdatedEvent`, `ScreenErrorDetectedEvent`, `OverlayOpenedEvent`, `OverlayClosedEvent`, `ContextRedactedEvent`, `SpeechCommandReceivedEvent`, `MemoryUpdatedEvent`, `ProactiveSignalGeneratedEvent`, `AndroidConnectedEvent`, `AndroidDisconnectedEvent`, `RuntimeReadyEvent`, `SubsystemRecoveredEvent`, `SubsystemFailedEvent`.
- **AmbientContextEngine** ✅ — Passive coordinator. 30s normal / 8s watch mode sampling. Privacy-gated via `PrivacyFilter`. Feeds `ContextEngine.recordScreen()`. Publishes `ScreenContextUpdatedEvent` and `ScreenErrorDetectedEvent` on every capture. `activateWatchMode(duration:targetApp:)` / `deactivateWatchMode()`.
- **ActiveAppMonitor** ✅ — NSWorkspace `didActivateApplicationNotification` + CGWindowListCopyWindowInfo (permission-free). Publishes `AppFocusChangedEvent`. Suppresses duplicate events (same bundleID + windowTitle).
- **WindowContextMonitor** ✅ — 5s polling for window title changes via CGWindowListCopyWindowInfo.
- **PrivacyFilter** ✅ — Blocks password managers (1Password, Bitwarden, Keychain), incognito browser windows. Configurable additional blocked bundleIDs and name substrings.
- **AmbientContextModels** ✅ — `ActiveApp`, `ScreenContextSummary`, `WatchModeState`, `AmbientContext`, `ContextConfidence`.
- **AmbientContextOverlayView** ✅ — Debug overlay showing active app, latest summary, watch mode, recent SystemBus events colour-coded by category. Triggered by "show ambient context" / "ambient debug".
- **New intents** ✅ — `whatAmIWorkingOn`, `whatChangedOnScreen`, `whatFailedOnScreen`, `showAmbientContextOverlay`, `enableAmbientContext`, `disableAmbientContext`, `watchThis`, `stopWatching`.

### Sprint G feature notes
- **RuntimeSubsystem protocol** ✅ — `@MainActor protocol RuntimeSubsystem`. Fields: `id`, `displayName`, `state: RuntimeState`, `startupOrder: Int`, `canRecoverIndependently`. Methods: `start/stop/healthCheck/recover`. `RuntimeState` enum: stopped/starting/running/degraded/failed. `HealthStatus` enum: healthy/degraded(String)/failed(String).
- **RuntimeCoordinator** ✅ — `@MainActor final class RuntimeCoordinator`. Singleton `shared`. Subsystem registry (`register()`), ordered startup (`sortedSubsystems`), health monitor (30s polling), isolated recovery (`attemptRecovery(id:)`, max 3 retries), readiness state (`ReadinessState`: booting/ready/degraded/failed). Publishes `RuntimeReadyEvent`, `SubsystemRecoveredEvent`, `SubsystemFailedEvent` to SystemBus. JarvisController calls `markReady()` after bootstrap.
- **RuntimeRegistry** ✅ — 8 thin shell conformances in one file: `SystemRuntime` (order 10), `MemoryRuntime` (20), `AudioRuntime` (30), `ConversationRuntime` (40), `OverlayRuntime` (50), `AmbientRuntime` (60), `LLMRuntime` (70), `ProactivityRuntime` (80), `AndroidRuntime` (90). Health checks delegate to `AppState.DeviceStatus`. No logic duplication — JarvisController still owns actual service lifecycle.
- **EventStore** ✅ — `@MainActor final class EventStore`. 1000-event ring buffer. `subscribeAll` catch-all subscriber. Query by category/source/priority/time/type/correlationID. `throughput(windowSeconds:)` for diagnostics. Started by `SystemRuntime` during bootstrap.
- **TaskThreadEngine** ✅ — `@MainActor final class TaskThreadEngine`. Subscribes to `AppFocusChangedEvent`, `ScreenContextUpdatedEvent`, `ScreenErrorDetectedEvent`. Builds `TaskThread` models: id, title, apps[], entities[], errors[], confidence, isActive. Starts new thread on app change or 30-min idle. `taskThreadEngine` property on JarvisController, started after bootstrap.
- **AppContextAdapter** ✅ — `protocol AppContextAdapter` with `bundleID`, `appName`, `extractContext(windowTitle:ocrLines:) -> AppContext`. Concrete adapters: `CursorAdapter`, `XcodeAdapter`, `TerminalAdapter`, `SafariAdapter`. `AppContextAdapterRegistry.shared` for lookup. `AppContext` model: activeFile, repoName, branchName, projectName, activeURL, terminalCommand, buildStatus, selectedText, confidence.
- **ContextConfidence** ✅ — Struct in `AmbientContextModels.swift`. Fields: score, measuredAt, freshness. Computed `level: ContextConfidenceLevel` (unknown/low/medium/high). `shouldSpeak`, `shouldProact` gates. `decayed(by:halfLife:)` for time-based decay.
- **RuntimeDiagnosticsOverlayView** ✅ — Developer overlay (`.runtimeDiagnostics` kind, `.medium` size, `.indigo` accent). Shows all subsystem states + restart counts, EventStore throughput bar chart (60s window), current TaskThread. Auto-refreshes every 2s via Timer. Triggered by "runtime diagnostics" / "subsystem health".
- **pbxproj prefixes** — `RC` (RuntimeSubsystem/Coordinator/Registry), `EV` (EventStore), `TH` (TaskThreadEngine), `XA` (AppContextAdapter), `RT` (RuntimeDiagnosticsOverlayView).

### Sprint H feature notes
- **ConversationRuntime (real class)** ✅ — `Core/ConversationRuntime.swift`. `@MainActor final class ConversationRuntime: RuntimeSubsystem` (startupOrder=40). Owns: `isArmed`, `isSessionActive`, `pendingContext`, arm/timeout/await-response Tasks, all conversation state. Injected callbacks: `onStartListening`, `onStopListening`, `onReturnToPassiveWake`, `isListening`, `isSpeaking`, `listeningEnabled`, `mediaIsPlaying`, `conversationalTimeoutSeconds`, `followUpEnabled`, `persistentConversationEnabled`. Publishes: `ConversationStartedEvent`, `ConversationEndedEvent`, `ConversationTimedOutEvent`, `ConversationFollowUpRequestedEvent`, `ConversationFollowUpResolvedEvent`, `ConversationAwaitingResponseEvent`. Diagnostics: `sessionCount`, `followUpCount`, `timeoutCount`, `lastSessionStartedAt`, `lastEventName`. JarvisController holds `let conversation = ConversationRuntime()` and wires callbacks in bootstrap. Thin shell in RuntimeRegistry.swift removed.
- **ExecutionTrace** ✅ — `Core/ExecutionTrace.swift`. `TraceStep` (id, name, at, detail, runtimeID). `ExecutionTrace` (correlationID, label, startedAt, steps, completedAt, summary). `ExecutionTracer.shared` singleton: `begin(label:) -> UUID`, `addStep(_:detail:runtimeID:)`, `complete()`, `completeAndBegin(label:)`, `activeCorrelationID`, `recentTraces(limit:)`. 50-trace ring buffer. JarvisController instruments the full pipeline: `handleWakeEvent` → `begin`, `startListening` → `addStep("listening")`, `handleTranscript` → `addStep("transcript")`, intent resolved → `addStep("intent_resolved")`, `speak` → `addStep("tts")`, TTS finish → `complete()`.
- **RuntimeDependencyGraph** ✅ — `Core/RuntimeDependencyGraph.swift`. `RuntimeDependencyEntry` (id, dependsOn, softDependsOn). `RuntimeDependencyGraph.shared` with 9 entries. Methods: `hardDependencies(of:)`, `softDependencies(of:)`, `restartPrerequisites(for:)`, `dependents(of:)`, `topologicalOrder()` (DFS), `isHardBlocked(_:by:)`. Dependencies: system→[], memory→[system], audio→[system], conversation→[audio,system], overlay→[system], ambient→[system,overlay], llm→[system,memory], proactivity→[system,overlay,conversation], android→[system].
- **New SystemBus event types** ✅ — 12 new structs in `Core/SystemEventTypes.swift`: `ConversationStartedEvent`, `ConversationEndedEvent(permanent:reason:)`, `ConversationFollowUpRequestedEvent(question:responseType:correlationID:)`, `ConversationFollowUpResolvedEvent(resolution:correlationID:)`, `ConversationAwaitingResponseEvent(question:correlationID:)`, `ConversationTimedOutEvent`, `WakeDetectedEvent(keyword:confidence:correlationID:)`, `ListeningStartedEvent(reason:correlationID:)`, `ListeningStoppedEvent(reason:correlationID:)`, `TTSStartedEvent(textPreview:correlationID:)`, `TTSFinishedEvent(correlationID:)`, `IntentResolvedEvent(transcript:intentLabel:resolvedBy:correlationID:)`.
- **Event publishing in JarvisController** ✅ — `handleWakeEvent` publishes `WakeDetectedEvent` + begins ExecutionTrace. `startListening` publishes `ListeningStartedEvent`. `stopListening` publishes `ListeningStoppedEvent`. `speak` publishes `TTSStartedEvent`. TTS finish publishes `TTSFinishedEvent` + completes ExecutionTrace. `handleTranscript` adds trace step + calls `conversation.cancelTimeout()`. `!llmHandled` branch publishes `IntentResolvedEvent` just before `execute(intent)`.
- **ProactivityEngine SystemBus integration** ✅ — `subscribeSystemBus()` / `unsubscribeSystemBus()` methods. Subscribes to `ConversationAwaitingResponseEvent` → sets `isPaused = true`. Subscribes to `ConversationFollowUpResolvedEvent` → sets `isPaused = false`. Called from JarvisController bootstrap after `onPresent` callback is wired. Tokens stored as `SystemBus.SubscriptionToken?`.
- **pbxproj prefixes** — `CR` (ConversationRuntime), `ET` (ExecutionTrace), `DG` (RuntimeDependencyGraph).

### Brain Phase 1 feature notes
- **BrainModels** ✅ — `Brain/BrainModels.swift`. All Brain-layer value types: `BrainMemorySource` (10 cases incl. memoryExtractor, voiceCommand, userEdited), `BrainPrivacyLevel` (normal/sensitive/private), `BrainTaskType` (10 cases), `BrainTaskStatus` (queued/running/paused/cancelled/completed/failed; isActive/isTerminal computed). `BrainTask` struct. `EpisodeType` (9 cases). `ConversationEpisode` struct with relatedMemoryIds, relatedEntityIds, dominantApps, dominantTopics, dominantProjects, tags, durationMinutes. Five SystemBus event structs: `BrainMemoryWrittenEvent`, `BrainTaskQueuedEvent`, `BrainTaskStatusChangedEvent`, `BrainEpisodeStartedEvent`, `BrainEpisodeEndedEvent`.
- **BrainMemoryStore** ✅ — `Brain/BrainMemoryStore.swift`. `@MainActor final class`, `static let shared`. Authoritative durable long-term memory. `configure(db:semanticIndex:)` called by BrainRuntime. `autoCommitThreshold = 0.49`. `commit(_:)` guards: discards `.discard` type, private memories only if voiceCommand/userEdited source, Jaccard 75% dedup, bounded cache (500 in-memory). `search(query:limit:)` hybrid FTS5 + semantic, excludes private. `contextForLLM(query:maxItems:)` returns `[BRAIN MEMORY CONTEXT]` block. Score: `importance × confidence × (1 − ageDays/60)`. `sweepExpired()` cleans entries past expiresAt.
- **BrainTaskQueue** ✅ — `Brain/BrainTaskQueue.swift`. `@MainActor final class`, `static let shared`. Durable restart-safe queue. `configure(db:)` + `restoreFromDisk()` resets `.running` → `.queued`. `enqueue` prevents duplicate active tasks of same type. `fail` auto-requeues if `retryCount < maxRetries`. `nextQueued` sorts by priority then createdAt. Publishes `BrainTaskQueuedEvent`, `BrainTaskStatusChangedEvent`.
- **EpisodeStore** ✅ — `Brain/EpisodeStore.swift`. `@MainActor final class`, `static let shared`. Time-bounded activity grouping. `beginEpisode` closes active first, publishes `BrainEpisodeStartedEvent`. `maybeAutoStart` opens new episode after 30-min idle gap. `linkMemory`, `linkEntity`, `recordApp`, `recordTopic` associate data with active episode. `todaysSummary()` and `weekSummary()` for voice/proactivity. Queries: `recentEpisodes(limit:)`, `episodesOnDate(_:)`, `search(query:)`.
- **BrainRuntime** ✅ — `Brain/BrainRuntime.swift`. `RuntimeSubsystem` (id="brain", startupOrder=25, between MemoryRuntime=20 and AudioRuntime=30). Opens own `JarvisDatabase(url: JarvisDatabase.standardURL)` connection (WAL mode safe). Creates `SemanticMemoryIndex(filename:"brain_semantic_index.json")`. Calls `configure` on all three stores. `sweepExpired()` on detached utility Task. Health: `.degraded("No database connection")` if db nil.
- **SemanticMemoryIndex filename param** ✅ — `init(filename: String = "semantic_index.json")`. Existing callers unchanged. BrainRuntime passes `"brain_semantic_index.json"` to avoid file collision with the main semantic index.
- **RuntimeDependencyGraph** ✅ — Added `brain` entry: `dependsOn: ["memory"]`, `softDependsOn: ["llm"]`.
- **RuntimeBootstrapper** ✅ — `BrainRuntime()` registered between `MemoryRuntime()` and `AudioRuntime(appState:)`.
- **MemoryCandidate extensions** ✅ — 7 new fields on existing struct (all with defaults): `importance`, `updatedAt`, `expiresAt`, `source: BrainMemorySource`, `linkedEntityIds`, `originalConversationId`, `privacyLevel`.
- **EntityGraph extensions** ✅ — 8 new `EntityKind` cases (repo, file, feature, bug, decision, haEntity, githubIssue, githubPR), `EntityDomain` enum, `domain` computed property. 7 new `RelationshipKind` cases (blocks, fixes, contradicts, dependsOn, supersedes, requestedBy, implementedIn).
- **JarvisDatabase extensions** ✅ — `standardURL` static property. CRUD for `brain_memories` (insertBrainMemory, deleteBrainMemory, recentBrainMemories, brainMemoriesByType, searchBrainMemories FTS5, sweepExpiredBrainMemories). CRUD for `brain_tasks` (upsertBrainTask, allActiveBrainTasks). CRUD for `brain_episodes` (upsertBrainEpisode, recentBrainEpisodes). Row types: `BrainMemoryRow`, `BrainTaskRow`, `BrainEpisodeRow`.
- **DatabaseMigrator v4** ✅ — `brain_memories` table (17 cols, FTS5 virtual table + trigger), `brain_tasks` table (15 cols, indexes, auto-prune trigger), `brain_episodes` table (14 cols, started_at index).
- **pbxproj prefix** — `BN` (group `BN00...GRP`, build files `BN01...0001–0008`, file refs `BN02...0001–0008`).

### Sprint P (Brain phases 3-5) feature notes
- **Phase 3 — LLM context injection** ✅ — `Core/LLMFallbackHandler.swift`. After Obsidian vault RAG block, calls `await BrainMemoryStore.shared.contextForLLM(query: rawText, maxItems: 5)`. Returns `[BRAIN MEMORY CONTEXT]` block injected into LLM context. Skips non-`.normal` privacy entries. Score-ranked by `importance × confidence × (1 − ageDays/60)`.
- **Phase 4 — Brain Governance UI** ✅ — `UI/BrainOverlayView.swift`. Three-tab browser: **Memories** (sorted by importance×confidence, type badge, score bar, swipe-delete, swipe-pin), **Episodes** (recent sessions with dominant topics, duration, EpisodeType.systemImage), **Tasks** (non-terminal BrainTaskQueue entries with status colour). Search bar triggers `BrainMemoryStore.shared.search()` on submit. `.brain` OverlayKind: indigo accent, large size, isImplemented.
- **Voice commands** ✅ — `showBrainOverlay` ("show brain", "open brain", "brain memory"), `brainSummaryToday` ("brain summary", "what do you remember today"), `brainSummaryWeek` ("brain week", "what have you learned this week"). All wired in CommandModels, CommandPhraseDefaults, IntentMapping, IntentRouter, ResponseTemplate, ResponsePlaybook, JarvisController.execute().
- **BrainTaskQueue.allActive()** ✅ — New query returning non-terminal tasks sorted by priority (desc) then createdAt (asc).
- **Phase 5 — BrainDreamCycle** ✅ — `Brain/BrainDreamCycle.swift`. Fires every 2 hours (5-min initial boot delay). Three operations: (1) Promotes `ConversationMemoryStore.shared.memoryItems` with confidence ≥ 0.65 into `BrainMemoryStore.shared` (source = `.dreamCycle`, importance floor from `importanceFor(type:)` helper). (2) `BrainMemoryStore.shared.sweepExpired()`. (3) Closes active episode idle > 4h via `EpisodeStore.endActiveEpisode`. BrainRuntime starts/stops dreamCycle alongside bridges.
- **pbxproj entries** — `BN01/BN02...0009` (BrainOverlayView.swift in UI group), `BN01/BN02...0010` (BrainDreamCycle.swift in Brain group).

### Sprint U feature notes
- **ContextGraphPersistence** ✅ — `ContextGraph/ContextGraphPersistence.swift`. Atomic JSON save to `~/Library/Application Support/JarvisMac/context_graph.json`. 3-second debounce via cancelled Task. Schema version 1 field; load silently skips newer payloads (forward compat). `load(into:)` filters edges whose endpoints were removed (dangling-edge safety). Custom `fileURL: URL?` init for test isolation. `resetPersistedFile()` for tests and schema migrations.
- **Prune** ✅ — `ContextGraph.prune(policy:) -> PruneResult`. Three phases: (1) stale inferred nodes (confidence < 0.40 AND age > 30 days) removed unconditionally; (2) over-cap: weakest inferred nodes evicted by `confidence × ageFactor`; (3) edge cap: lowest-confidence edges dropped. `PrunePolicy` struct (defaults: maxNodes=800, maxEdges=1500). `PruneResult(nodesRemoved:edgesRemoved:)` with `isEmpty`. Called after all ingestion in `refresh()`.
- **Enrichment** ✅ — `ingestGitHubNotifications([GHNotification])` creates `.githubIssue` nodes linked to `.githubRepo` project nodes. `ingestTodoistTasks([TodoistAPIClient.Task])` creates `.todoistTask` nodes (`.synced` trust tier). `enrichCrossLinks()` adds `sameTopicAs` edges between `taskThread` and `memory` nodes sharing ≥5-char keywords. New source closures `getGitHubNotifications`/`getTodoistTasks` wired in JarvisController (empty defaults; no sync cache exists yet).
- **loadFromDisk()** ✅ — Called in JarvisController bootstrap before the initial refresh Task so history survives restarts.
- **Diagnostics** ✅ — `ContextGraphDiagnostics` extended with `persistedGraphLoaded`, `lastSaveTime`, `lastPruneResult`, `nodeCap`, `edgeCap`. `persistenceOneLiner` string. `RuntimeDiagnosticsOverlayView.contextGraphSection` now shows persistence status (green=loaded, yellow=cold start) and cap utilisation percentages.
- **Answer Composer** ✅ — `activeContinuityChain` capped at 3 nodes. Graph block header now shows `N nodes · E edges · treat as supplemental`. Budget accounting initialises from header length.
- **Tests** ✅ — `ContextGraphPersistenceTests.swift` (11 tests): save/load round-trip, corrupt JSON, missing file, dangling edges, stale inferred prune, high-trust preservation, edge-cap enforcement, edge dedup, keyword cross-link, budget safety, pbxproj UUID check.
- **pbxproj entries** — `CGP01/02` (ContextGraphPersistence.swift in main app ContextGraph group), `CPT01/02` (ContextGraphPersistenceTests.swift in test target).

### Sprint V feature notes
- **ContextRanking** ✅ — `ContextGraph/ContextRanking.swift`. Deterministic 5-dimension relevance scoring. `rank(nodes:relativeTo:context:) -> [NodeScore]` returns nodes sorted high→low. Dimensions: recency (0.25 weight, linear decay over 48h), confidence (0.25), trust (0.20; system=0.60, synced=0.75, userEdited=1.00, inferred=0.35), corroboration (0.15; distinct neighbour sources × 0.33), focusAlignment (0.15; topic+app=1.0, topicOnly=0.65, appOnly=0.40). `significantWords(in:)` is `internal static` so `ProjectRelationshipIndex` can build focus keyword sets. `@MainActor` on graph-touching methods.
- **ProjectFocusState** ✅ — `ContextGraph/ProjectFocusState.swift`. Non-singleton, owned by `ProjectRelationshipIndex`. Hysteresis guard: incumbentBonus=0.15 applied before comparison; changeThreshold=0.12 required delta above adjusted incumbent. minConfidence=0.35 gate. `recentTransitions` ring buffer (cap 10). `FocusContext` struct (dominantProject, confidence, rankedNodes [NodeScore], reason). `FocusTransition` struct for diagnostics.
- **ProjectRelationshipIndex updates** ✅ — `private let focusState = ProjectFocusState()`. `refresh()` calls `updateFocusState()` after `enrichCrossLinks()`. `updateFocusState()` computes per-project weighted scores (confidence × recency × trust) and feeds `focusState.update(candidates:)`. `activeFocusContext() -> FocusContext` ranks all non-noise nodes via `ContextRanking.rank()` using active thread apps + focus keywords as `RankingContext`. Fixed `activeContinuityChain` bug (was `|| true`; now prefers `isActive == "true"` thread). `diagnostics` now includes `focusConfidence`, `previousFocusProject`, `rankedNodeCount`, `suppressedNodeCount` and uses `focusCtx.dominantProject` as `topActiveProject`. Fixed `activeThread?.apps` bug (apps are in `metadata["apps"]` as comma-separated string, not a property).
- **JarvisAnswerComposer update** ✅ — `buildGraphContextBlock()` now calls `activeFocusContext()` instead of `activeContinuityChain`. Filters out uncorroborated inferred nodes (trustTier == .inferred AND corroboration == 0). Uses top 3 from ranked candidates. Focus header: `[GRAPH CONTEXT — active project focus: X (82% confidence)]` when focus is stable; falls back to node/edge count header.
- **RuntimeDiagnosticsOverlayView update** ✅ — Added `focusOneLiner` line after persistence status: cyan when active project detected (confidence > 0), dim white when no focus.
- **ContextGraphDiagnostics** ✅ — 4 new fields in `ContextProvenance.swift`: `focusConfidence: Double`, `previousFocusProject: String?`, `rankedNodeCount: Int`, `suppressedNodeCount: Int`. New `focusOneLiner` computed property.
- **Tests** ✅ — `ContextRankingTests.swift` (11 tests): significantWords filtering + lowercasing + deduplication, trustScore ordering, fresh vs. weak node rank order, corroboration zero for isolated / positive for multi-source, focusScore zero / topicOnly / topicAndApp, rank descending order, ProjectFocusState below-threshold / strong candidate / hysteresis block / strong challenger displacement.
- **pbxproj entries** — `RK01/02` (ContextRanking.swift), `PF01/02` (ProjectFocusState.swift) in main app ContextGraph group; `VT01/02` (ContextRankingTests.swift) in test target.

### Sprint W feature notes
- **FocusContextResponder** ✅ — `ContextGraph/FocusContextResponder.swift`. `@MainActor enum` with 3 static methods: `workingSummary()` (graph focus + thread + top node), `leftOffSummary()` (recent thread + continuity chain + project), `whyFocused()` (confidence pct + top 3 supporting nodes with trust labels + reason). Always returns `""` on no-data for caller to fall back to ResponseKey. `whyFocused()` always returns non-empty string.
- **FocusAwarenessDocContributor** ✅ — `@MainActor final class` in same file. id=`"context.focus_awareness"`, category=`.diagnostics`. Shows live node count, focus confidence, and 8 example phrases. Registered in JarvisController `registerBuiltInDocumentationContributors()`.
- **New intents** ✅ — `showFocus` ("show focus", "show context graph", "focus state", "show recent work sessions") and `explainCurrentFocus` ("why do you think that", "explain current focus", "what project am I focused on", "what are you basing that on"). Both wired in CommandModels, CommandPhraseDefaults, IntentMapping, IntentRouter, ResponseTemplate, ResponsePlaybook, JarvisController.execute().
- **Improved handlers** ✅ — `whatAmIWorkingOn` now prepends `FocusContextResponder.workingSummary()` (graph focus prefix at >40% confidence) before ambient/thread context. `whatWasIDoingEarlier` now leads with `FocusContextResponder.leftOffSummary()` instead of raw thread summary.
- **New phrases** ✅ — "where did I leave off" and "where did we leave off" added to `what_was_i_doing` command.
- **execute() handlers** ✅ — `showFocus`: opens `.runtimeDiagnostics` overlay + speaks `workingSummary(concise:true)`. `explainCurrentFocus`: speaks `whyFocused()` directly (no overlay).
- **Tests** ✅ — `FocusContextResponderTests.swift` (11 tests): workingSummary empty/populated, leftOffSummary empty/with memory node, whyFocused graceful fallback (always non-empty), whyFocused with populated graph, contributor stable id, contributor non-nil section with examples, pbxproj UUID uniqueness.
- **pbxproj entries** — `FC01/02` (FocusContextResponder.swift in main app ContextGraph group), `FT01/02` (FocusContextResponderTests.swift in test target).

### Sprint X feature notes
- **AppleNotesService** ✅ — `Integrations/AppleNotesService.swift`. `enum` with 4 static async-throwing methods: `createNote(title:body:)` (returns confirmed title), `appendToNote(title:body:)` (finds note by contains-match, appends timestamped block), `searchNotes(query:limit:)` (returns `[AppleNote]` parsed from result string), `openNotes()`. All throw `NotesError.scriptingUnavailable` on permission failure or `NotesError.notFound` when append target is missing. `escaped(_:)` handles `\` and `"` in AppleScript strings.
- **NotesIntentHandler** ✅ — `Integrations/NotesIntentHandler.swift`. `@MainActor final class` following Shopify/Todoist handler pattern. Handles: `.openNotes`, `.showNotes`, `.createNote(title:body:)`, `.appendNote(title:body:)`, `.searchNotes(query:)`. Empty title/body/query paths speak a clarifying question + `setPendingContext`. Permission errors speak `notesPermissionError` key. Successful operations call `ingestNode?` to push an `.appleNote` node into `ContextGraph.shared`.
- **ContextGraph integration** ✅ — `ContextSource.appleNotes` case added to `ContextSource`. `ContextNodeType.appleNote` case added to `ContextNodeType`. Ingested nodes use `trustTier: .userEdited`, `confidence: 0.90`, `externalID: "applenote:<slug>"` for deduplication.
- **New intents** ✅ — `createNote(title:body:)`, `appendNote(title:body:)`, `searchNotes(query:)`, `openNotes`, `showNotes` in `CommandModels.Intent`. All wired in CommandPhraseDefaults (`.startsWith` match type for parameterised commands), IntentMapping, IntentRouter, ResponseTemplate, ResponsePlaybook, JarvisController.
- **execute() dispatch** ✅ — `case .openNotes, .showNotes, .createNote, .appendNote, .searchNotes: await notesIntentHandler.handle(intent)`.
- **Tests** ✅ — `AppleNotesIntentHandlerTests.swift` (11 tests): return-value routing, non-notes intent false, empty-title/body/query pending-context paths, ingestNode hook reachability, node shape (type/source/trustTier/confidence), `escaped()` backslash+quote and safe-string cases, pbxproj UUID regression guard.
- **pbxproj prefixes** — `AN01/02` (AppleNotesService.swift), `NH01/02` (NotesIntentHandler.swift) in Integrations group; `NT01/02` (AppleNotesIntentHandlerTests.swift) in test target.
- **PhraseMatchType note** — `CommandPhraseDefaults.def()` uses `.startsWith` (not `.prefix`) for parameterised phrase matches. CLAUDE.md had the wrong enum name; corrected in Sprint X.

### Brain Phase 2 feature notes
- **EpisodeBrainBridge** ✅ — `Brain/EpisodeBrainBridge.swift`. Subscribes to `AppFocusChangedEvent` → `EpisodeStore.maybeAutoStart(appName:)`. Subscribes to `ConversationStartedEvent` → `EpisodeStore.maybeAutoStart(topicHint:"voice")`. Subscribes to `IntentResolvedEvent` → extracts camelCase prefix as topic label → `EpisodeStore.recordTopic`. Started/stopped by BrainRuntime.
- **GitHubBrainBridge** ✅ — `Brain/GitHubBrainBridge.swift`. Subscribes to `GitHubBuildFailedEvent` → commits `.bugReport` memory (confidence 0.90, importance 0.80, source `.github`). Subscribes to `AppFocusChangedEvent` for GitHub-family bundle IDs → `EpisodeStore.maybeAutoStart + recordApp`. Memory uses default `.normal` privacy (CI failures are not personal data).
- **HABrainBridge** ✅ — `Brain/HABrainBridge.swift`. Subscribes to `HAEntityChangedEvent`. Filtered domains: `lock` (importance 0.65) and `alarm_control_panel` (importance 0.70–0.95 depending on triggered/armed/disarmed). 5-minute per-entity dedupe window prevents burst noise. All HA memories use `.sensitive` privacy (never injected into LLM context). `friendlyName()` converts "lock.front_door" → "front door".
- **BrainRuntime bridge ownership** ✅ — BrainRuntime holds `episodeBridge`, `githubBridge`, `haBridge` as private properties. All three started in `start()`, stopped in `stop()`.
- **MemoryExtractor → BrainMemoryStore wiring** ✅ — `JarvisController.swift`. In the post-turn extraction Task, after existing `ConversationMemoryStore.saveMemory()` call: sets `source = .memoryExtractor`, computes `importance` via `brainImportance(for:)` helper (roadmapChange=0.85, projectDecision=0.80, projectProgress/personalFact=0.75, preference=0.70, bug=0.65, idea=0.60, else=0.30). Commits if `confidence × importance >= autoCommitThreshold`. Links committed memory to active episode via `EpisodeStore.shared.linkMemory`.
- **SearchService brain extension** ✅ — `Memory/SearchService.swift`. `hybridSearch` now fetches `BrainMemoryStore.shared.search(limit: limit/3)` in addition to FTS keyword + semantic hits. Brain candidates are appended after keyword/semantic results, deduplicated by 60-char text prefix. Brain results are formatted as "title: summary" for display.

### Sprint AA feature notes
- **AppleMailService** ✅ — `Integrations/AppleMailService.swift`. AppleScript-backed enum with static async methods: `getRecentMessages(limit:)`, `getUnreadMessages()`, `searchMessages(query:)`, `composeEmail(to:subject:body:)`, `openMail()`. Parses AppleScript coercion output into `AppleMailMessage` structs. Throws `MailError.scriptingUnavailable` on permission failure.
- **EmailIntentHandler** ✅ — `Integrations/EmailIntentHandler.swift`. `@MainActor final class` handling: `.openMail`, `.showMail`, `.checkEmail`, `.composeEmail(to:subject:body:)`, `.searchEmail(query:)`, `.readLatestEmail`. Empty parameter paths speak clarifying question + `setPendingContext`.
- **EmailProactivityProvider** ✅ — `Integrations/EmailProactivityProvider.swift`. Polls every 5 minutes. Surfaces unread messages as `ProactivitySignal` (priority `.normal`, source `.email`). `isFirstPoll` seed guard prevents startup flood.
- **New intents** ✅ — `openMail`, `showMail`, `checkEmail`, `composeEmail(to:subject:body:)`, `searchEmail(query:)`, `readLatestEmail` in `CommandModels.Intent`.
- **Tests** ✅ — `AppleMailIntentHandlerTests.swift` (11 tests).
- **pbxproj prefixes** — `EM01/02` (AppleMailService, EmailIntentHandler, EmailProactivityProvider in Integrations), test file in JarvisMacTests.

### Sprint AB feature notes
- **MacBrain HTTP Service** ✅ — Lightweight NWListener-based HTTP/1.1 JSON API server at `http://localhost:8765` (default). Three endpoints: `GET /brain/health`, `POST /brain/context`, `POST /brain/interactions`. Designed for Android Jarvis to use as a local "Brain" service.
- **Security** ✅ — Optional Bearer token auth (`Authorization: Bearer <token>`). Token stored in macOS Keychain under `KeychainAccount.brainServerToken` — never logged, never in preferences. `bindLocalOnly` flag defaults off (configurable). No raw audio, no screenshots, no chain-of-thought, no huge payloads, no remote-control backchannel.
- **MacBrainServer** ✅ — `MacBrain/MacBrainServer.swift`. Plain class (NOT @MainActor), own `DispatchQueue`. NWListener on TCP port. HTTP/1.1 parsing: splits at `\r\n\r\n`, parses request line + headers, extracts body. Auth check before dispatch. `start(port:bindLocalOnly:)` / `stop()`.
- **BrainHTTPHandler** ✅ — `MacBrain/BrainHTTPHandler.swift`. `@MainActor final class`. Routes GET/POST to correct handler. Context endpoint: `withTaskGroup` 1500ms global timeout around `contextEngine.buildContext`. Interactions routing by `eventType`.
- **BrainContextEngine** ✅ — `MacBrain/BrainContextEngine.swift`. `BrainContextProviding` protocol. Sequential provider calls each with 500ms `withTaskGroup` timeout. Category filter from request.
- **Context providers** ✅ — `MemoryContextProvider` (BrainMemoryStore search), `ProjectContextProvider` (activeFocusContext + todaysSummary), `PreferenceContextProvider` (safe prefs only — never tokens), `HomeAssistantAliasProvider` (alias store), `GitHubContextProvider` (sync cache via `lastFetchedNotifications`).
- **Interaction stores** ✅ — `BrainInteractionStore` (500 cap, `brain_interactions.json`), `BrainCorrectionStore` (200 cap, `brain_corrections.json`), `BrainMemoryCandidateStore` (100 cap, `brain_memory_candidates.json`). All append-only, dedup by eventId. `BrainMemoryCandidateStore` auto-promotes candidates with `confidence >= 0.65` and title+summary to `BrainMemoryStore.shared.commit()`.
- **BrainDiagnostics** ✅ — `MacBrain/BrainDiagnostics.swift`. `@Observable @MainActor final class`. Tracks requests served, unauthorized attempts, last context time. `authToken` computed from Keychain — never stored in-memory beyond the call.
- **MacBrainSettingsView** ✅ — `UI/MacBrainSettingsView.swift`. Sections: Enable/disable, Status (green dot + stats), Network (port stepper 1024–65535 + bind-local toggle), Authentication (SecureField + copy + regenerate). Token backed by Keychain.
- **Preferences** ✅ — 3 new fields: `brainServerEnabled: Bool = false`, `brainServerPort: UInt16 = 8765`, `brainServerBindLocalOnly: Bool = false`. All decoded with `decodeIfPresent` fallback.
- **JarvisController wiring** ✅ — `startBrainServer()`, `stopBrainServer()`, `restartBrainServer()` methods. All providers wired with closures (weak self). GitHub sync cache via `githubClient?.lastFetchedNotifications`.
- **GitHubAPIClient** ✅ — Added `var lastFetchedNotifications: [GHNotification] = []` sync cache.
- **GitHubProactivityProvider** ✅ — Sets `client.lastFetchedNotifications = notifications` after each successful poll.
- **Settings tab** ✅ — New "Brain API" tab (Group 3) with `dot.radiowaves.up.forward` SF symbol. `minWidth` bumped 1200→1280.
- **Tests** ✅ — `MacBrainServerTests.swift` (21 tests): health, context, interactions, auth, dedup, cap, promotion, diagnostics, contextEngine filter.
- **pbxproj prefix** — `HB` (group `HB00A2B3C4D5E6F7A8B9CGRP`, build files `HB01...001-015`, file refs `HB02...001-015`).

### Sprint AC feature notes
- **Mac Camera HTTP Server** ✅ — Adds `/camera/health`, `/camera/snapshot`, `/camera/stream` routes to the existing `MacBrainServer` on port 8765. Mac-side only; Android integration is a future phase.
- **MacCameraService** ✅ — `MacBridge/MacCameraService.swift`. `@MainActor final class NSObject`. Owns `AVCaptureSession` + `AVCaptureVideoDataOutputSampleBufferDelegate`. Session management on private `sessionQueue`. JPEG encoding via `ImageIO` (`CGImageDestination`) — no AppKit/NSBitmapImageRep on the capture thread. `QualityBox: @unchecked Sendable` inner class with `NSLock` bridges JPEG quality from `@MainActor` setter to `nonisolated` delegate without actor violation. `checkPermission()` / `requestPermission()` / `start()` / `stop()`.
- **MacCameraFrameStore** ✅ — `MacBridge/MacCameraFrameStore.swift`. `@MainActor final class`. Retains only the single latest JPEG frame. `update(jpeg:)` / `clear()` / `latestJPEG` / `lastFrameTime`.
- **MacCameraDiagnostics** ✅ — `MacBridge/MacCameraDiagnostics.swift`. `@Observable @MainActor final class`. Tracks `isEnabled`, `permission`, `isCapturing`, `activeViewers`, `lastFrameTime`, `lastStreamError`, `totalFrames`. `CameraLogEvent` enum covers all CAMERA_* log events. `statusLine` computed property for UI display.
- **MacCameraHttpRoutes** ✅ — `MacBridge/MacCameraHttpRoutes.swift`. `@MainActor final class`. Three handlers: `handleHealth()` (sync), `handleSnapshot()` (async, 2s wait loop), `handleStream(connection:)` (async, takes NWConnection ownership indefinitely). MJPEG streaming via single background `Task` loop at `fpsInterval`, sequential writes to all active clients. Disconnect detection: `stateUpdateHandler` (.failed/.cancelled) + `NWConnection.send()` completion error — both call idempotent `removeClient(id:)`. `stopAll()` cancels task + all connections + stops camera.
- **MacBrainServer routing** ✅ — Camera paths (`/camera/*`) checked BEFORE brain auth check, with their own independent `requireCameraToken` flag. `sendBinary()` helper added for non-JSON `Content-Type` responses (JPEG + MJPEG headers). `/camera/stream` does NOT cancel `conn` — `handleStream` takes ownership.
- **MacCameraSettingsView** ✅ — `UI/MacCameraSettingsView.swift`. Embedded in `MacBrainSettingsView` Camera Streaming section. Groups: Enable toggle, Status grid (permission/capturing/viewers/last frame/last error), Capture (FPS picker 1/5/10 + JPEG quality low/medium/high + keepCameraWarm checkbox), Auth (require-token checkbox), Endpoint URLs, orange "camera is being viewed" viewer banner.
- **Preferences** ✅ — 5 new fields: `cameraServerEnabled: Bool = false`, `cameraServerRequireToken: Bool = true`, `keepCameraWarm: Bool = false`, `cameraFPS: Int = 5`, `cameraJPEGQuality: String = "medium"`. All decoded with `decodeIfPresent` fallback.
- **JarvisController wiring** ✅ — `cameraService`, `cameraFrameStore`, `cameraDiagnostics` properties. Bootstrap calls `cameraService.checkPermission()`. `startBrainServer()` creates and wires `MacCameraHttpRoutes` when `cameraServerEnabled`. `fpsIntervalForCameraFPS(_:)` and `jpegQualityForSetting(_:)` private helpers.
- **Auth** ✅ — `requireCameraToken` defaults `true`. Uses same Keychain token as Brain API (`diagnostics.authToken`). Token never logged. Returns 401 on missing/wrong token.
- **Actor isolation pattern** ✅ — `QualityBox: @unchecked Sendable` with `NSLock`. The `AVCaptureVideoDataOutputSampleBufferDelegate` is `nonisolated`; `@MainActor` properties cannot be read from it. `qualityBox.get()` is safe from any isolation context.
- **Tests** ✅ — `MacCameraServerTests.swift` (15 tests): MacCameraFrameStore (starts empty, latest-only, clear, timestamp), MacCameraDiagnostics (initial state, enabled/disabled, client count, floor-at-zero, permission denied, frame timestamp), MacCameraHttpRoutes (health does not start camera, health response fields, snapshot 503 timeout, activeClientCount starts at zero), pbxproj UUID regression.
- **pbxproj prefix** — `MC` (group `MC00A2B3C4D5E6F7A8B9CGRP`, build files `MC01...001-006`, file refs `MC02...001-006`). MacBridge folder inside `JarvisMac/`.

### Sprint AD feature notes
- **LocalLearningEngine** ✅ — `LocalLearning/LocalLearningEngine.swift`. `@MainActor final class`. Orchestrates all 7 stores. `handle(transcript:)` pre-LLM check order: (1) successful route cache (hitCount≥2), (2) learned alias match, (3) recent corrections, (4) local LLM query. `detectAndRecordCorrection` fired in `handleTranscript` before ConversationRouter. `exportTrainingData()` writes 4 files to `~/JarvisTrainingData/`. LoRA stubs: `exportForLoRATraining()`, `setLoRAAdapterPath()`, `setTunedModelEndpoint()`. `checkEndpointHealth()` pings `/health` endpoint.
- **LocalLLMClient** ✅ — `LocalLearning/LocalLLMClient.swift`. URLSession-based. OpenAI-schema body for openAICompatible/llamaCpp/mlxServer, Ollama-schema (`/api/chat` + `stream:false`) for ollama. Strips markdown fences from response. Validates `LocalLLMStructuredResponse` (confidence≥0.45, non-empty intent+response, response<500 chars). Throws `LocalLLMError.lowConfidence` for uncertain results.
- **LocalLLMConfig** ✅ — `LocalLearning/LocalLLMConfig.swift`. `LocalLLMProvider` enum with `chatPath`, `usesOpenAISchema`, `defaultBaseURL`. `LocalLLMConfig` struct (enabled, provider, baseURL, modelName, apiKey?, timeoutSeconds, maxTokens, temperature). Shared enums: `InteractionSource`, `ApprovalState`, `ExampleSource`, `AliasSource`.
- **7 learning stores** ✅ — All persist to `~/Library/Application Support/JarvisMac/ll_*.json`:
  - `InteractionRecorder` — in-memory 500-record ring; `successRate` computed; no persistence (session only)
  - `CorrectionDetector` — pure enum; 10 regex patterns; `detect(transcript:lastTranscript:)`
  - `LearnedCommandAliasStore` — `ll_aliases.json`, 500 cap; `match()` exact/prefix/contains; approval workflow
  - `FailedUtteranceStore` — `ll_failures.json`, 200 cap; deduped by normalized transcript; `top()` by attemptCount
  - `UserCorrectionStore` — `ll_corrections.json`, 200 cap
  - `SuccessfulRouteStore` — `ll_successful_routes.json`, 300 cap; `match()` requires hitCount≥2; rolling confidence avg
  - `LocalConversationMemoryStore` — in-memory 100-turn sliding window; `buildContextBlock()` for LLM prompt
  - `TrainingExampleStore` — `ll_training_examples.json`, 2000 cap; `exportJSONL(approved:pending:)`; `validate()`
- **LLMFallbackHandler integration** ✅ — `learningEngine: LocalLearningEngine?` and `routeFromString: ((String) -> Intent?)?` injected. Pre-cloud-LLM check at top of `handle(rawText:normalized:)`: if engine returns result → speak clarification or executeIntent via routeFromString. Falls through to cloud LLM if engine returns nil.
- **JarvisController wiring** ✅ — `learningEngine` property. `detectAndRecordCorrection` checked in `handleTranscript` between voice-learning and ConversationRouter. `buildLocalLLMConfig()` helper reads 8 prefs fields. `learningEngine.routeFromString` closure delegates to `self.router.route()`. Speaks `ResponseKey.learningAcknowledge` on correction.
- **Preferences** ✅ — 8 new fields: `localLLMEnabled/Provider/BaseURL/ModelName/ApiKey/TimeoutSecs/MaxTokens/Temperature`. All `decodeIfPresent` with safe defaults.
- **Training Data UI** ✅ — `UI/TrainingDataView.swift`. 4-tab segmented picker: Examples (list with approve/reject/delete/edit-notes, search, export button, validate button), Aliases (list with approve/reject), Failed (list with mark-resolved/clear), Diagnostics (endpoint health, routing counts, store counts, LoRA stubs). Export writes to `~/JarvisTrainingData/` with 4 JSONL/MD files.
- **SettingsView** ✅ — `training` tab added (graduationcap icon) in Group 3.
- **pbxproj prefix** — `LN` (group `LN00A2B3C4D5E6F7A8B9CGRP`, build files `LN01...001-012`, file refs `LN02...001-012`). LocalLearning folder inside `JarvisMac/`.

### Sprint L feature notes

**Phase 1 — Conversational Core**
- **IntelligenceModels** ✅ — `Intelligence/IntelligenceModels.swift`. `DialogueTurn` struct: role (user/assistant), transcript, topic, entities, emotionalTone (neutral/frustrated/excited/stressed/tired/curious), intentLabel, route, wasInterruption, `isRecent: Bool { ageSeconds < 300 }`. Also: `ImplementationStatus` enum (6 cases), `FeatureNode`, `CodeChunk`, `SelfQueryResult`.
- **RollingDialogueMemory** ✅ — `Conversation/RollingDialogueMemory.swift`. `@MainActor final class`, singleton. 40-turn cap, 5-min recency window. `addUserTurn(_:intent:route:wasInterruption:)`, `addAssistantTurn(_:intent:)`. Entity extraction (quoted strings + capitalized non-stop words). Emotional tone detection (≥2 frustration signals → `.frustrated`, etc.). `resolve(_ word:) -> String?` for pronoun resolution. `isRepeatRequest(_:) -> Bool`. `buildContextBlock(limit:) -> String` returns `[DIALOGUE CONTEXT]` block for LLM injection. `activeTopic`, `activeEntities`, `emotionalTone` properties.
- **ConversationRouter MIXED detection** ✅ — `classifyFast()` now detects `commandPrefix + conjunction + conversational aside` before the command prefix check. Returns `.mixedChatAndCommand` (confidence 0.85) with `commandHint`. Conjunctions: `, but `, `, though `, `, although `, `, however `, `, yeah `, ` but yeah `, ` and yeah `, ` but also `, ` although `, ` even though `, ` but i `, ` though i `, ` but the `, ` but that `. Only for transcripts > 25 chars.
- **ConversationRoute.shouldShortCircuit** ✅ — `.mixedChatAndCommand` added to the guard list, so mixed utterances fall through to the intent pipeline rather than short-circuiting.

**Phase 2 — Silent Action Execution**
- **ActionPolicy** ✅ — `Conversation/ActionPolicy.swift`. `silentSuccess = true`, `speakOnFailure = true`, `speakOnClarification = true`, `speakOnDestructive = true`. `resultsMatterLabels` set (weather, email read, time, etc.). `destructiveLabels` set (clearMemory, deleteFile, etc.). `.default`, `.verbose` (silentSuccess:false), `.minimal` presets. `shouldSpeak(intentLabel:result:userRequestedConfirmation:) -> Bool`.
- **suppressNextSpeak** ✅ — `Bool` property on JarvisController. Checked at the VERY TOP of `speak()` before any side effects (no TTS, no chat message, no rolling memory, no conversation save). Consumed (reset to false) on first use.
- **CHAT_PLUS_TOOL dual-track** ✅ — In `handleTranscript`: when `lastConvRouteResult?.route == .mixedChatAndCommand && confidence >= 0.70`, sets `suppressNextSpeak = true` before `execute(intent)` (Track B — silent command), then calls `handleConversationalTurn` for Track A (spoken reply). Diagnostics logged when `conversationalDiagnosticsEnabled`.

**Phase 3 — Codebase Intelligence**
- **CodebaseIndexer** ✅ — `Intelligence/CodebaseIndexer.swift`. `@MainActor final class`, singleton. Off-actor `Task.detached(priority: .utility)`. Skips: DerivedData, .git, build, node_modules, xcuserdata, .claude, Pods, worktrees. Swift: MARK headers + symbol decls, 80-line chunks. Markdown: heading-split, 120-line + 3000-char cap. JSON: whole file ≤50KB. `reindex(projectRoot:)`, `loadFromDisk()`, `search(query:limit:language:) -> [CodeChunk]`, `chunks(forFeature:) -> [CodeChunk]`. Persisted to `codebase_index.json`. `onIndexingComplete` callback.
- **ProjectKnowledgeGraph** ✅ — `Intelligence/ProjectKnowledgeGraph.swift`. `@MainActor final class`, singleton. ~30 seeded `FeatureNode` entries (all major Jarvis features with implementationFiles, status, dependencies). `loadOrSeed(projectRoot:)` + `enrich(projectRoot:)` (off-actor, checks file existence). `feature(named:) -> FeatureNode?`, `features(matching:) -> [FeatureNode]`. Persisted to `project_knowledge_graph.json`.
- **JarvisSelfQueryService** ✅ — `Intelligence/JarvisSelfQueryService.swift`. `static let shared`. `isAboutSelf(_ normalized:) -> Bool` — 25 signal phrases. `query(userQuery:activeTopic:) async -> SelfQueryResult?`. `buildGroundedAnswer()` — uses `ImplementationStatus` to phrase answers factually; never invents state. `contextBlock(for:) -> String` — returns `[JARVIS SELF-KNOWLEDGE]` block with "DO NOT invent details" instruction. Wired in `handleConversationalTurn` (step 0.5) and `LLMFallbackHandler`.

**Phase 5 — Persistent Proactivity Engine**
- **ProactiveEvent** ✅ — `Core/ProactiveEvent.swift`. `struct ProactiveEvent: Identifiable`. Fields: id, source, urgency, confidence, title, body, timestamp, expiresAt, relatedEntity, isActionable, interruptibilityScore. `isExpired: Bool`. `interruptibilityScore` defaults from `urgency.defaultInterruptibilityScore`.
- **ProactiveEventSource** ✅ — 15 cases: calendar, todoist, github, homeAssistant, shopify, email, news, diagnostics, wifi, location, camera, projectState, system, voice, brain.
- **ProactiveUrgency** ✅ — `Comparable` enum: critical/high/normal/low. `defaultInterruptibilityScore` (1.0/0.85/0.55/0.25). `defaultCooldownSeconds` (0/30/120/300).
- **ProactiveDeliveryDecision** ✅ — 6 cases: speakNow, defer_, bundle, overlayOnly, silentMemory, suppress.
- **AttentionContext** ✅ — `Core/AttentionPolicy.swift`. Snapshot: isUserSpeaking, isJarvisSpeaking, isListening, isFocusModeActive, isInActiveMeeting, currentApp, emotionalTone, secondsSinceLastInterruption, secondsSinceLastConversation, isUserAtHome, recentInterruptionCount, conversationDepth.
- **AttentionPolicy** ✅ — `@MainActor struct`. `decide(event:context:) -> ProactiveDeliveryDecision`. Logic: critical bypasses all → speakNow. User/Jarvis speaking → defer. Meeting → overlayOnly (high) or suppress (normal/low). DeepWork app → overlayOnly (high) or defer. Frustrated/stressed → bundle (low priority). Tired → silentMemory (normal/low). Spam guard (>6/10min) → bundle (high) or suppress. Min gap (15s) → bundle. Low interruptibilityScore (<0.40) → bundle. Default → speakNow.
- **ProactivityOrchestrator** ✅ — `Core/ProactivityOrchestrator.swift`. `@MainActor final class`, singleton. Callbacks: `onSpeak: ((String)->Void)?`, `onSignal: ((ProactivitySignal)->Void)?`, `getAttentionContext: (()->AttentionContext)?`. 30s delivery cycle. 5-min escalation threshold. 3-event bundle window. `publish(_ event:)` — critical triggers immediate cycle. `deliverBundle()` → `onSpeak`. `deliverOverlay()` → `onSignal → engine.ingest`. `buildDefaultContext(isSpeaking:isListening:currentApp:)` reads `RollingDialogueMemory.shared`. `mapSource/mapUrgency` helpers for ProactivityEngine compatibility. Wired in `JarvisController.bootstrap()`.

**Phase 9 — Emotional Context Adaptation**
- **JarvisAnswerComposer** ✅ — `compose()` gains `toneHint: String? = nil`. `buildSystemPrompt()` appends `\n\nIMPORTANT — user emotional state: <hint>` to every route's system prompt when provided. `.mixedChatAndCommand` gets its own system prompt: "Respond only to the conversational part. Do NOT acknowledge or confirm the command."
- **handleConversationalTurn** ✅ — Computes `toneHint` from `rollingMemory.emotionalTone`: frustrated → "Be brief, direct, skip all preamble.", stressed → "Be calm, concise, and reassuring.", tired → "Keep the response short and simple."

**Phase 13 — Settings**
- **IntelligenceSettingsView** ✅ — `UI/IntelligenceSettingsView.swift`. Sections: Codebase Intelligence (self-knowledge toggle + description), Codebase Index (enabled toggle + file/chunk counts + last-indexed + re-index button), Silent Actions (toggle + description), Proactive Delivery (delivery cycle stepper 10-120s, escalation threshold stepper 1-30min, bundle window stepper 1-6 events, min interruption gap stepper 5-120s, max alerts/10min stepper 1-20), Feature Graph (feature count + DisclosureGroup status overview with color dots).

**Phase 14 — Tests**
- **ConversationalArchitectureTests** ✅ — `JarvisMacTests/ConversationalArchitectureTests.swift`. 35 tests covering: ActionPolicy (9), RollingDialogueMemory (5), ConversationRouter mixed detection (4), ConversationRouteResult.shouldShortCircuit (4), AttentionPolicy decisions (7), ProactiveEvent model (5), JarvisSelfQueryService.isAboutSelf (1), pbxproj UUID uniqueness (1). Note: test runner hangs at startup (pre-existing test host issue ~333s timeout) — this is an infra issue not a code issue.

**New preferences (Sprint L)**
- `codebaseIndexEnabled: Bool = true`
- `codebaseIndexPath: String? = nil`  
- `silentActionsEnabled: Bool = true`
- `selfKnowledgeEnabled: Bool = true`

**Architecture decisions (Sprint L)**
- ProactivityOrchestrator sits ABOVE ProactivityEngine: orchestrator handles attention-gating/bundling/escalation; engine handles cooldowns/tray/overlay management. Providers still call `engine.ingest()` directly — provider→orchestrator migration is a future sprint (needs careful dedup design).
- `suppressNextSpeak` checked at TOP of `speak()` before all side effects so suppressed calls leave zero observable trace (no chat bubble, no rolling memory, no conversation save).
- MIXED detection runs BEFORE command prefix scan so the full utterance is visible before the command portion short-circuits.
- toneHint passed to `buildSystemPrompt()` as a suffix clause so tone adaptation is composable with any route's system prompt without re-implementing each case.

**Remaining from Sprint L spec (deferred)**
- Interruptible streaming / barge-in sentence pivoting (Phase 6)
- Passive vision context (Phase 7 — VisionContext in AppState exists but not persistent)
- Internal multi-agent coordination (Phase 10)
- Phase 11 architecture self-explanation
- Quiet hours enforcement in orchestrator (currently in engine only)

### Sprint M feature notes

**Phase 1 — Provider → Orchestrator migration** ✅
- All 8 proactivity providers now call `ProactivityOrchestrator.shared.providerPublish(signal:)` instead of `engine.ingest(signal, appState:)` directly.
- `providerPublish` converts `SignalPriority` → `ProactiveUrgency`, `SignalSource` → `ProactiveEventSource`, creates a `ProactiveEvent`, stores the original signal in `pendingSignals[event.id]` for delivery, and triggers an immediate delivery cycle for urgency >= `.high`.
- Stored signals used in `deliverSingleEvent`/`deliverBundle`/`deliverOverlay` so `spokenText` and `overlayKind` are preserved through the attention policy.
- Providers that still need `engine` ref (for settings checks): `EmailProactivityProvider` (`engine.settings.emailEnabled`), `HomeAssistantProactivityProvider` (`engine.settings.ha*`).
- `markDelivered` now cleans up `pendingSignals` to prevent unbounded growth.

**Phase 2 — New components** ✅
- **`ConversationalTimingEngine`** (`Core/ConversationalTimingEngine.swift`) — tracks user/Jarvis speech turn timing. `isGoodTimeToSpeak`, `isUserIdle`, `recommendedDelaySeconds(urgency:)`. Updated by `rewireSpeakingObserver` (TTS) and `handleTranscript` (user speech).
- **`AmbientWorldState`** (`Core/AmbientWorldState.swift`) — central snapshot of active app, media, calendar, conversation state. `attentionContext(timingEngine:recentInterruptionCount:)` builds `AttentionContext` from live state. Feeds `orchestrator.getAttentionContext`.
- **`WorldStateAggregator`** (same file) — subscribes to SystemBus `AppFocusChangedEvent`, `ConversationStartedEvent`, `ConversationEndedEvent`, `SpeechCommandReceivedEvent` and updates `AmbientWorldState`.
- **`RuntimeHealthMonitor`** (`Core/RuntimeHealthMonitor.swift`) — detects repeated failures (STT/TTS/LLM/HA/network). `recordFailure(_:detail:)` accumulates; crossing `failureThreshold` (default 3) within `windowSeconds` (120s) fires a `.high` ProactivitySignal via `providerPublish`. Per-subsystem cooldown (`alertCooldownSeconds = 300`). `recordRecovery` clears cooldown.
- **pbxproj prefixes** — `CT` (ConversationalTimingEngine), `AW` (AmbientWorldState), `RH` (RuntimeHealthMonitor).
- **Tests** — `SprintMTests.swift` (20 tests): timing engine (7), world state (6), health monitor (3), provider publish (2), pbxproj UUID regression (1).

### Sprint N feature notes

**Phase 1 — Streaming Interruption** ✅
- **`ConversationalPivotPlanner`** (`Conversation/`) — tracks spoken/unspoken sentence clauses mid-response. `classify(_ text:) -> InterruptionKind` (correction/clarification/topicShift/urgentCommand/confirmation/expansion). `buildPivotContext(interruptionText:) -> PivotContext`. `PivotContext.contextBlock()` produces LLM-injectable block: "Was saying: … Had planned: … User interrupted: …".
- **`StreamingConversationEngine`** (`Conversation/`) — sentence-level TTS streaming. `beginStreaming(fullText:) -> Bool` splits text and speaks first sentence. `advanceIfStreaming()` called from `rewireSpeakingObserver` to advance queue. `handleInterruption(userText:)` halts queue and fires `onPivot`. `cancelStream()` for "stop talking". Falls back to single-shot TTS for short texts.
- **Integration point**: call `streamingEngine.advanceIfStreaming()` from `rewireSpeakingObserver` when `isSpeaking = false`; call `streamingEngine.handleInterruption(userText:)` from `handleTranscript` when barge-in detected during streaming.

**Phase 2 — Episodic Memory** ✅
- **`EpisodicMemoryStore`** (`Brain/`) — memories with session context (dominantApp, topic, projectName, emotionalContext). Jaccard 70% dedup. `relevanceScore = importance × confidence × ageFactor`. `contextForLLM(query:maxItems:)` for LLM injection. JSON persistence at `episodic_memory.json`.
- **`MemoryImportanceScoring`** (`Brain/`) — static scoring enum. `baseScore(for: MemoryCandidateType)` (roadmapChange=0.75 … discard=0.0). `emphasisBonus`, `repetitionBonus`, `decayPenalty`. `EmotionalWeight.from(tone:)` converts `DialogueTurn.EmotionalTone` to bonus.
- **`EpisodicMemoryRetriever`** (`Brain/`) — `RetrievalMode` enum: `.semantic`, `.timeline`, `.projectScoped`, `.unresolved`, `.composite`. All synchronous. `forCurrentProject()` reads `AmbientWorldState.shared.activeProject`. `contextBlock(for:limit:)` for LLM.
- **`MemoryConsolidationWorker`** (`Brain/`) — 4h background sweep. Merge: Jaccard ≥ 72% same-type duplicates. Auto-resolve: same project+topic decision pairs (keep newest). Decay: age > 45 days AND importance < 0.35. Promote: importance ≥ 0.75 AND confidence ≥ 0.65 → `BrainMemoryStore.shared.commit()`.

**Phase 3 — Passive Vision** ✅
- **`PersistentVisionContext`** (`Vision/`) — snapshot: `presenceKind: UserPresenceKind` (.present/.away/.unknown), `attentionState: AttentionState` (existing enum). `isDeskOccupied` = present AND confidence ≥ 0.55. `isFresh` = updated within 90s. Publishes `UserPresenceDetectedEvent`/`UserAwayDetectedEvent` on SystemBus. JSON persistence.
- **`SceneChangeDetector`** (`Vision/`) — call `reportPresence(isPresent:confidence:)` from JarvisController camera pipeline. N-frame hysteresis (default 3) before committing state change to `PersistentVisionContext`. Debounces rapid changes. Publishes `SceneChangedEvent`.
- **`VisionStateSummary`** (`Vision/`) — static enum. `isUserPresent`, `isDeskEmpty`, `contextBlock()` for LLM, `oneLiner()` for diagnostics.
- **`UserPresenceKind`** enum — distinct from `PresenceState` struct in `CameraModels.swift` which counts people. This is the coordinator-level "is user here?" state.

**Phase 4 — Predictive Assistance** ✅
- **`BehaviourPatternEngine`** (`Intelligence/`) — records `(intentLabel, hour, weekday, app)` tuples; bucketed to 3-hour windows. `occurrenceCount` builds to `confidence` (capped at 1.0 at 20 occurrences). `currentContextPatterns(app:limit:)` returns strong patterns (count ≥ 5, confidence ≥ 0.60) matching ±1h window. Persisted to `behaviour_patterns.json`.
- **`PredictiveSuggestionEngine`** (`Intelligence/`) — anti-spam: 60s idle gate, 15min cooldown, 4/hour cap, per-intent 30min cooldown. `emitTopSuggestionIfReady()` publishes `.low` priority signal via `ProactivityOrchestrator`. Phrase lookup table maps intentLabel → conversational suggestion phrase.
- **`ReminderEscalationModel`** (`Intelligence/`) — 3-stage escalation: 10min pre-warning (.normal), 5min warning (.high), 2min imminent (.urgent). `track(title:dueDate:source:)` registers. `checkEscalations()` called on 60s poll. Snooze/dismiss API. Persisted to `reminder_escalations.json`.

**Phase 5 — Central Runtime Coordination** ✅
- **`JarvisRuntimeCoordinator`** (`Core/`) — higher-level than `RuntimeCoordinator` (lifecycle). Arbitrates `CoordinationDemand` (.speak/.showOverlay/.startListening/.stopListening/.escalateAlert/.requestMemoryWrite). Critical urgency bypasses TTS check. Normal/low suppressed when listening. High queued 2s when TTS active. Memory writes deferred during active conversation (confidence < 0.85). 50-decision ring buffer.
- **`RuntimeReasoningLayer`** (`Core/`) — static enum. `explainLastDecision()`, `explainDeliveryDecision(for:)` (simulates AttentionPolicy decision), `currentStateSummary()` (timing+streaming+world+vision+pivot state), `workContextExplanation()` (app+project+episodic memories+vision).

**pbxproj prefixes** — `PL` (ConversationalPivotPlanner), `SE` (StreamingConversationEngine), `ES` (EpisodicMemoryStore), `MI` (MemoryImportanceScoring), `MR` (EpisodicMemoryRetriever), `MW` (MemoryConsolidationWorker), `PC` (PersistentVisionContext), `SD` (SceneChangeDetector), `VN` (VisionStateSummary), `BP` (BehaviourPatternEngine), `PS` (PredictiveSuggestionEngine), `RM` (ReminderEscalationModel), `JR` (JarvisRuntimeCoordinator), `RZ` (RuntimeReasoningLayer), `SN` (SprintNTests).
- **Tests** — `SprintNTests.swift` (30 tests): pivot planner (7), streaming engine (5), episodic store (3), importance scoring (4), vision context (3), scene detector (2), behaviour patterns (2), reminder escalation (2), runtime coordinator (3), pbxproj UUID regression (1).

**Deferred from Sprint N spec — all wired in `0e9f234` (Sprint N wiring):**
- `StreamingConversationEngine.advanceIfStreaming()` in `rewireSpeakingObserver`
- `StreamingConversationEngine.handleInterruption()` in `handleTranscript` barge-in path
- `BehaviourPatternEngine.recordIntent()` in `execute()` defer block
- `PredictiveSuggestionEngine.emitTopSuggestionIfReady()` on idle detection
- `ReminderEscalationModel.track()` from CalendarProactivityProvider
- `SceneChangeDetector.reportPresence()` from camera pipeline
- `EpisodicMemoryStore.loadFromDisk()` + `MemoryConsolidationWorker.start()` in BrainRuntime
- `PersistentVisionContext.loadFromDisk()`, `BehaviourPatternEngine.loadFromDisk()`, `ReminderEscalationModel.start()`, `JarvisRuntimeCoordinator` wiring in bootstrap

### Sprint O feature notes

**Overview** — Hardening/stabilisation sprint. No new user-facing features. All components are non-breaking additions and filters layered on top of existing infrastructure.

**Phase 1 — BehaviourScenarioRunner** ✅ — `Core/BehaviourScenarioRunner.swift`. QA harness for automated scenario testing. `ScenarioStep` with 12 `StepKind` cases: `injectSignal`, `setWorldState`, `setVisionState`, `simulateInterruption`, `setEmotionalTone`, `wait`, `expect`- prefixed assertions, `runBundleCheck`, `expectBundleText`, `expectLatencyRecorded`, `expectHealthAlert`. 7 built-in scenarios: `noise_dedup`, `smart_bundle`, `vision_hysteresis`, `memory_noise`, `health_dedup`, `streaming_double_interrupt`, `latency_recording`. `runAll() async -> [ScenarioResult]`. Accessible from diagnostics.

**Phase 2 — LatencyBudgetSystem** ✅ — `Core/LatencyBudgetSystem.swift`. `@MainActor final class`. 9 `BudgetKind` cases with ms targets: `routeClassification(50)`, `firstSpokenToken(500)`, `llmFirstChunk(800)`, `ttsStart(200)`, `wakeToListening(100)`, `memoryRead(50)`, `visionFrame(33)`, `intentExecution(150)`, `fullTurn(2000)`. Ring-buffer per kind (100 samples). `p50/p95` computed. `budgetViolations(since:)`. `startTimer() -> CFAbsoluteTime`. Wired into `handleTranscript` for `routeClassification` timing.

**Phase 3 — ProactivityNoiseController** ✅ — `Core/ProactivityNoiseController.swift`. `@MainActor final class`. Anti-spam layer: `sameKeyMinIntervalSeconds = 300` (2× when frustrated), `maxEventsPerHour = 8`, `maxSameSourcePerHour = 3`, repeated-ignored suppression (≥3 ignores suppresses key for 1h). `tryBundle([ProactivitySignal]) -> BundledSignals?` for 2–4 signals with shared topic. `buildBundleText(from:)` generates: "Two things — X and Y." / "3 quick things: X, Y, and Z." Wired into `ProactivityOrchestrator.deliverBundle()` replacing robotic "Also — X and Y." pattern.

**Phase 4 — MemoryValidationLayer** ✅ — `Brain/MemoryValidationLayer.swift`. `@MainActor enum`. Quality gate for `EpisodicMemoryStore.register()`. Rejects: `.discard` type, <4 words, STT noise (<3 letter chars), false wakes (wake word variants + single-word), weak chatter (filler set of 25 phrases), below threshold (importance <0.25 OR confidence <0.35). Applies STT confidence penalty. Penalises transient notes in shallow sessions.

**Phase 5 — StreamingRecoveryLayer** ✅ — `Conversation/StreamingRecoveryLayer.swift`. `@MainActor final class`. Edge case handler for `StreamingConversationEngine`. 7 `RecoveryReason` cases. 4 `RecoveryAction` cases: `resumeFromSpoken`, `restartWithContext`, `silentDiscard`, `fallbackSingle(String)`. Rapid-repeat detection (<2s = `isRapidRepeat`). Double-interruption → `silentDiscard`. Empty stream → `fallbackSingle`. `recoveryCount`, `recoveryReport` for diagnostics.

**Phase 6 — VisionEfficiencyController** ✅ — `Vision/VisionEfficiencyController.swift`. `@MainActor final class`. 5 `FrameRateTier` cases: `suspended(0)`, `minimal(1fps)`, `low(3fps)`, `normal(5fps)`, `watch(10fps)`. `recommendedTier(isConversing:isWatchActive:isUserPresent:timeSinceLastChange:)`. `suspendWhenIdleMinutes = 30`. `shouldCommitPresenceChange(from:to:confidence:consecutiveFrames:)`: high confidence (≥0.85) needs 2 frames, medium (0.65–0.85) needs 3, low needs 5. `recordSignificantChange()` resets idle timer. Wired into `SceneChangeDetector.reportPresence()`.

**Phase 7 — RuntimeHealthDedup** ✅ — `Core/RuntimeHealthDedup.swift`. `@MainActor final class`. Severity scoring: `SeverityScore.overallScore = importance×0.4 + userImpact×0.3 + repeatFactor×0.3`. Score must exceed 0.5 to alert. `alertCooldownSeconds = 600` (10 min). `evaluate(event:) -> Bool` (`@discardableResult`). `recordRecovery(subsystem:)` clears cooldown. Wired into `RuntimeHealthMonitor.emitAlert()` as additional gate after monitor's own cooldown.

**Phase 8 — Natural bundle text** ✅ — `ProactivityOrchestrator.deliverBundle()` now uses `ProactivityNoiseController.shared.tryBundle()` for natural-language bundling. Fallback uses "Also — X and Y." (still robotic but only reached when NoiseController has no matching bundle).

**pbxproj prefixes** — `LB` (LatencyBudgetSystem), `PN` (ProactivityNoiseController), `RD` (RuntimeHealthDedup), `QR` (BehaviourScenarioRunner), `MV` (MemoryValidationLayer), `SL` (StreamingRecoveryLayer), `VF` (VisionEfficiencyController), `OT` (SprintOTests).
**Tests** — `SprintOTests.swift` (37 tests): LatencyBudgetSystem (5), ProactivityNoiseController (6), RuntimeHealthDedup (5), BehaviourScenarioRunner (4), MemoryValidationLayer (6), StreamingRecoveryLayer (5), VisionEfficiencyController (5), pbxproj UUID regression (1).

### Sprint Q feature notes

**Post-tool conversational continuation + vision action chaining.** Enables queries like "open the camera and tell me if I am soaking" to produce a real spoken reply after frame analysis, rather than silently executing the tool with no follow-up.

- **`ToolExecutionGraph`** ✅ — `ContextGraph/ToolExecutionGraph.swift`. `@MainActor final class`. 9 `StageKind` cases: `openCamera`, `waitForFrame`, `captureFrame`, `runVisionSummary`, `ocrAnalysis`, `screenshotAnalysis`, `diagnosticsAnalysis`, `browserInspection`, `regionUnderstanding`. `Stage` struct with per-stage `timeoutSeconds`. `execute(stages:query:stageRunner:) async -> GraphResult` uses `withTaskGroup` per stage for timeout isolation. `GraphResult.combinedContext` filters out control-signal stages (openCamera, waitForFrame) — only content stages are injected into LLM context. 50-diagnostic ring buffer with `ExecutionDiagnostic` lifecycle timestamps and `postToolResponseGenerated` flag.
- **`PostToolContextInjection`** ✅ — `ContextGraph/PostToolContextInjection.swift`. `@MainActor final class`. Callbacks: `onInjectAndReason: ((String, String) async -> Void)?`, `onFallback: ((String) -> Void)?`. `inject(result:) async` — fires fallback if no content stages completed; otherwise calls `buildContextBlock()` and triggers LLM reasoning. `buildContextBlock()` labels each content stage result and appends "Answer the user's question directly." instruction. Filters openCamera/waitForFrame as control signals.
- **`VisionActionPipeline`** ✅ — `Vision/VisionActionPipeline.swift`. `@MainActor final class`. Config: `cameraWarmupSeconds = 1.5`, `captureTimeoutSeconds = 4.0`. Callbacks: `onOpenCamera`, `captureVisionSummary: (() async -> String?)?`, `onLLMReason`, `onFallback`. `run(query:) async` executes 4-stage ToolExecutionGraph (open→wait→capture→summarize), calls `onFallback` if no frame, otherwise calls `onLLMReason(context, query)`. `cachedFrameDescription` prevents calling `captureVisionSummary` twice. `ScreenshotActionPipeline` in same file for screenshot path.
- **`ConversationRoute.chatPlusToolPlusReasoning`** ✅ — New case in `ConversationRoute.swift`. `shouldShortCircuit = true` at confidence 0.88, so JarvisController intercepts before the command pipeline.
- **`ConversationRouter` detection** ✅ — Step 1.7 in `classifyFast()`, between mixed-chat detection (1.5) and command prefix check (2). Two static tables: `toolTriggers: [(phrase, hint)]` (14 entries: camera/screenshot/diagnostics/browser variants) and `reasoningConnectors: [String]` (14 entries: "and tell me", "and explain", "then tell me", etc.). Returns `.chatPlusToolPlusReasoning` when transcript contains both a trigger and a connector.
- **`LLMFallbackHandler.temporaryAdditionalContext`** ✅ — `String?` one-shot property. Set by `PostToolContextInjection` before calling `handle()`. Consumed and cleared inside `handle()` between the vision context block and `PromptBudgeter.diagnose()`. Ensures post-tool context is injected exactly once.
- **`JarvisController` wiring** ✅ — `handleToolPlusReasoning(transcript:normalized:toolHint:) async` dispatches by hint (camera→VisionActionPipeline, screenshot→ScreenshotActionPipeline, diagnostics→buildDiagnosticsSummary). `speakWithToolContext(query:context:) async` sets `temporaryAdditionalContext` then calls `tryLLMFallback`. VisionActionPipeline callbacks wired to `cameraAwareness.captureDescription()` for capture and `speak()` for fallback. `buildDiagnosticsSummary()` builds brief phase/STT/TTS/health/latency string.

**pbxproj prefixes** — `TG` (ToolExecutionGraph), `PT` (PostToolContextInjection), `VP` (VisionActionPipeline), `TR` (PostToolReasoningTests).
**Tests** — `PostToolReasoningTests.swift` (16 tests): ToolExecutionGraph (5), PostToolContextInjection (3), VisionActionPipeline (2), ConversationRoute (1), ConversationRouter (2), pbxproj UUID regression (1).

### Sprint R feature notes

**Entity-First Resolver — universal semantic entity resolution.** Specific named entities ("EuroNews") now outrank generic category intents ("news") across the whole app via a single resolution layer at step 2.7 in `handleTranscript`.

- **`EntityModels.swift`** ✅ — `EntityType` enum (17 cases: app, contact, haDevice, haRoom, newsChannel, youtubeChannel, website, stream, browserBookmark, githubRepo, appleNote, calendarEntity, todoistProject, shopifyProduct, mediaSource, customAlias, file, folder). `EntityAction` enum (open, play, show, send, search, navigate, control, create, find, call, unknown). `EntityCandidate` struct (entityId, displayName, entityType, provider, aliases, externalURL, bundleIdentifier, baseConfidence, score, matchReason). `EntityResolutionResult` struct. `EntityProvider` protocol.
- **`MediaEntityDatabase.swift`** ✅ — Built-in static database of 50+ known entities: news channels (EuroNews, BBC News, Sky News, Sky Sports, CNN, Fox News, Al Jazeera, Reuters, Bloomberg, The Guardian, CNBC, NBC/ABC/CBS News, TNT Sports, ESPN, TechCrunch, Wired, The Verge, Hacker News, Politico), streaming (YouTube, Netflix, Disney+, Apple TV, Spotify, Twitch, Prime Video, Hulu, BBC iPlayer, Channel 4, ITVX, DAZN, Peacock, Apple Music, Tidal, SoundCloud), common websites (GitHub, Reddit, X, LinkedIn, Instagram, Google, Slack, Notion, Shopify). Each entry has aliases including phonetic and typo variants.
- **`EntityFirstResolver.swift`** ✅ — `@MainActor final class`, singleton. `resolve(transcript:rawText:) async -> EntityResolutionResult?`. Runs all providers in parallel via `withTaskGroup`. Confidence threshold 0.72 to bypass generic pipeline. Clarification threshold 0.10 margin. `NounSpanExtractor` strips action verbs + articles, generates candidate spans (full phrase + individual words + qualifier-stripped variants). `EntityScorer` implements: exact (1.0), alias (0.97), prefix (0.75–0.90), fuzzy Jaro-Winkler (scaled ×0.88 at ≥0.82), phonetic Soundex (0.70–0.72), word overlap (0.50–0.70).
- **`EntityProviders.swift`** ✅ — `MediaEntityProvider` (MediaEntityDatabase), `AppEntityProvider` (NSWorkspace installed apps, cached at class load), `BrowserEntityProvider` (6 known web destinations), `HomeAssistantEntityProvider` (@MainActor, wraps HomeEntityAliasStore + HAEntityRegistry), `MemoryEntityProvider` (RollingDialogueMemory.activeEntities), `CustomEntityAliasProvider` (singleton, delegates to CustomEntityAliasStore).
- **`EntityIntentBinder.swift`** ✅ — `@MainActor enum`. `bind(_ result:) -> (intent: Intent, spokenPrefix: String)?`. Matrix: app→openApp(bundleID or name), haDevice→homeTurnOn(entityId), contact→callContact, newsChannel/stream/website/browserBookmark→openURL, fallback→openURL if externalURL else openApp. `clarificationText(for:against:)` produces "Did you mean X or Y?" Spoken prefix always contains entity display name (e.g. "Opening EuroNews.").
- **`CustomEntityAliasStore.swift`** ✅ — `@MainActor final class`, singleton. `AliasEntry: Codable` (alias, entityId, displayName, entityType, url). Persisted to `~/Library/Application Support/JarvisMac/custom_entity_aliases.json`. `save(_:)` replaces-or-appends by alias. `CustomEntityAliasProvider.learn(alias:for:)` called when user corrects a resolution.
- **`JarvisController` step 2.7** ✅ — After ConversationRouter, before phrase-store: `await EntityFirstResolver.shared.resolve(transcript:rawText:)`. If `needsClarification` → speak question + `activePendingContext`. If binding found → log, `speak(prefix)`, `await execute(intent)`, return. Falls through to existing pipeline otherwise. Bootstrap registers all providers via `registerDefaults(haAliasStore:haEntityRegistry:)`.

**Resolution pipeline (inside handleTranscript):**
```
Step 0: follow-up / pronoun resolution
Step 2.5: ConversationRouter (chat/project/memory short-circuit)
Step 2.7: EntityFirstResolver ← NEW
  ├─ "open euro news" → EuroNews (score 0.97) → openURL(euronews.com) ✓
  ├─ "open news" → no candidate ≥ 0.72 → falls through to showNews ✓
  ├─ "turn on kitchen light" → HA entity (score 0.95) → homeTurnOn ✓
  └─ "open bbc" → BBC News (score 0.97 alias) → openURL(bbc.co.uk/news) ✓
Step 3a: phrase-store matching
Step 4: IntentRouter
Step 5: LLM fallback
```

**Scoring algorithm summary:**
1. Exact display name match → 1.00
2. Exact alias match → 0.97
3. Prefix match (name starts with span or vice versa) → 0.75–0.90
4. Any alias prefix match → 0.70–0.85
5. Name contains span → 0.55–0.75
6. Jaro-Winkler ≥ 0.82 → JW × 0.88
7. Soundex phonetic → 0.70–0.72
8. Word overlap ≥ 50% → 0.50–0.70

**pbxproj prefixes** — `EL` (EntityModels), `MD` (MediaEntityDatabase), `EF` (EntityFirstResolver), `EG` (EntityProviders), `EI` (EntityIntentBinder), `CE` (CustomEntityAliasStore), `ER` (EntityFirstResolverTests).
**Tests** — `EntityFirstResolverTests.swift` (25 tests): NounSpanExtractor (4), EntityScorer exact/alias/fuzzy/phonetic/generic (5), Jaro-Winkler (3), Soundex (2), MediaEntityProvider (3), EntityIntentBinder (3), CustomEntityAliasStore round-trip (1), pbxproj UUID regression (1).

### Sprint P7 feature notes

**Distributed Brain + Windows Sidecar Orchestration** — 13 new files in `JarvisMac/DistributedBrain/`. Mac = brain/memory/orchestration authority; Windows = perception/execution/rendering surface. One conversation, one memory, one Jarvis identity. Initial implementation used SSE for Mac→Windows pushes (replaced by Sprint P8 WebSocket rewrite).

- **`DistributedBrainModels.swift`** ✅ — All shared types: `DeviceKind`, `DeviceParticipant`, `ConversationFrame` (role: user/assistant/system, sequenceNumber), `SpeakerLease` (ownerDeviceId, speechId, interruptionGeneration, isExpired), `PresenceSnapshot` (AttentionLevel: idle/browsing/working/codingFlow/meeting/confused), `ExecutionKind/Request/Result`, `OrchestrationDecision` (Verbosity: full/brief/silent/delegate), `BridgeMessageType` (SCREAMING_SNAKE_CASE), `BridgeMessageV2`, `SessionSyncState`.
- **`DistributedConversationCoordinator.swift`** ✅ — Singleton. `ingest(_ frame:) -> Bool` dedup by seenFrameIds (Set<String>), 40-turn cap. `buildContextBlock(limit:)` returns `[DISTRIBUTED DIALOGUE]` block. `recordMacUserTurn/AssistantTurn`. `sessionId: String?`.
- **`GlobalPresenceAggregator.swift`** ✅ — Singleton. Debounce 1s/device, 5-min retention, 10-snapshot cap. `update(_ snapshot:) -> Bool` applies PrivacyFilter() to OCR. `windowsPresence`, `allPresence`, `anyDeviceHasUserPresent`, `contextBlock()`. pbxproj prefix `PA` (was GA, renamed to avoid gesture collision).
- **`DistributedOrchestrationEngine.swift`** ✅ — Mac always responds. `computeVerbosity`: codingFlow→.brief, meeting→.silent. `shouldDelegateExecution`: only for browser/click intents when Windows user is browsing. `macDeviceId = "mac"`.
- **`SpeakerCoordinator.swift`** ✅ — `acquire/release(deviceId:speechId:)`. `interrupt(by:) -> Bool` — ONLY Mac (`"mac"`) may interrupt. `forceRelease()`. pbxproj prefix `SK` (was SC, renamed to avoid SpatialInteraction collision).
- **`DistributedReferenceResolver.swift`** ✅ — `resolve(_ phrase:) -> String?` maps "that PR"→window title, "that page"→browser URL, "that file"→coding file. `enrichedContext(for transcript:) -> String?` returns `[REFERENCE RESOLUTION]` block.
- **`RemoteExecutionCoordinator.swift`** ✅ — `submit(_ request:to:) async -> ExecutionResult?`. Bounded 10-request queue, 5s default timeout. `deliver(_ result:)` resolves `CheckedContinuation`.
- **`GlobalProactivityCoordinator.swift`** ✅ — `route(_ event:) -> RoutingDecision`. critical/high→Mac always; Windows-only presence→Windows; codingFlow→both. `AttentionContextProvider.shared` singleton bridges `isMacListening/Speaking` to non-isolated contexts.
- **`DistributedFallbackCoordinator.swift`** ✅ — `canAccept(_ frameId:) -> Bool` LRU seen-set cap 500. `markDisconnected/Reconnected` with 50-frame replay buffer. `sessionDivergenceCheck(macSequence:remoteSequence:) -> Bool` threshold=5.
- **`MacBridgeProtocolV2.swift`** ✅ — Initially SSE-based; fully replaced by WebSocket in Sprint P8.
- **`GlobalAttentionCoordinator.swift`** ✅ — `GlobalAttentionState`: idle/macActive/windowsActive/bothActive/codingFlow/meeting/transitioning. `currentState` (private setter). `refresh()` recomputes from Mac + Windows presence. `interruptibilityScore(urgency:)`. `verbosityHint() -> String?`.
- **`DistributedBrainDiagnostics.swift`** ✅ — `@Observable @MainActor`. Metrics: framesIngested/Rejected, leaseAcquisitions/Preemptions, sessionDivergenceEvents, executionRequestsSent/Received, wsClientsConnected, replayFramesIngested, activeReplaySessions. Latency ring buffer (100 samples): p50/p95LatencyMs. `markConnected/Disconnected(_ device:)`.
- **`DistributedBrainTests.swift`** ✅ — 16 tests covering all coordinators + pbxproj UUID regression.
- **Preferences** ✅ — `distributedBrainEnabled: Bool = false`.
- **JarvisController wiring** ✅ — When `distributedBrainEnabled`: v2Routes wired to MacBrainServer, RemoteExecutionCoordinator.onSendRequest, AttentionContextProvider, isMacListening/Speaking providers, reference resolver weak refs.
- **pbxproj prefix** — `DB` (group `DB00...GRP`), file prefixes: DM, DC, PA, DO, SK, DR, RX, GC, DF, BV, AC, DD (main app); DT (test).

### Sprint P8 feature notes

**WebSocket MacBridgeProtocolV2 + GlobalPresenceState.** Replaces the SSE-based Mac→Windows push channel with a proper RFC 6455 WebSocket server.

- **WebSocket upgrade** ✅ — `GET /v2/ws` with `Upgrade: websocket` header triggers `handleWebSocketUpgrade(headers:conn:)`. SHA1 accept key computed via `CryptoKit.Insecure.SHA1`. Sends `HTTP/1.1 101 Switching Protocols` + `session.start` message. Connection stays open indefinitely.
- **Frame codec** ✅ — `parseFrame(_:)` static: reads FIN/opcode/mask/payload from raw bytes (Array<UInt8> for clean indexing). Supports 126/127-byte extended length. Unmasks client→server frames. `encodeTextFrame(_:)` static: server→client unmasked text frames with length encoding. `closeFrame()` / `pongFrame()` helpers.
- **Typed inbound dispatch** ✅ — `WSInbound` struct (type, messageId, deviceId, seq, ts, payload as `[String:String]`). Decoded with custom `init(from:)` using `decodeIfPresent` fallbacks. Switch over `msg.type`:
  - `transcript.partial` — recorded in diagnostics only (no processing)
  - `transcript.final` — dedup via `DistributedFallbackCoordinator.canAccept`, ingest into `DistributedConversationCoordinator`, enrich via `DistributedReferenceResolver`, route to `onInboundTranscript` callback (skipped in replay mode)
  - `presence.update` — builds `PresenceSnapshot`, updates `GlobalPresenceAggregator`, `GlobalAttentionCoordinator`, `GlobalPresenceState`, fires `onInboundPresence`
  - `lease.request` — calls `SpeakerCoordinator.shared.acquire()`, sends `lease.grant` or `lease.denied`
  - `replay.begin` / `replay.end` — toggles `WSClient.isReplayMode`; replay frames are ingested into history but NEVER trigger live responses
  - `execution.result` — reconstructs `ExecutionResult`, delivers to `RemoteExecutionCoordinator`
  - `device.hello` — updates deviceId, registers `DeviceParticipant`, sends `hello.ack`
- **Mac→Windows push** ✅ — `pushReplyFinal(text:intentLabel:)`, `pushReplyPartial(text:)`, `pushOrchestrateSpeak(text:)`, `pushOrchestrateSilent(reason:)`, `pushProactiveNotify(title:body:urgency:)`. `pushEvent(type:BridgeMessageType:payload:)` shim maps legacy enum to dot-notation type strings.
- **Callbacks** ✅ — `onInboundTranscript: ((String, String) -> Void)?` (deviceId, enriched transcript), `onInboundPresence: ((PresenceSnapshot) -> Void)?`.
- **Legacy HTTP REST routes** ✅ — `handle(method:path:headers:body:conn:)` retained for `POST /v2/frame`, `POST /v2/presence`, `GET /v2/session`, `POST /v2/execution/result`, `POST /v2/device/hello`.
- **MacBrainServer routing** ✅ — Detects `path == "/v2/ws" && headers["upgrade"]?.lowercased() == "websocket"` → calls `handleWebSocketUpgrade(headers:conn:)` (non-cancelling); other `/v2/` paths fall through to REST routes. SSE `/v2/events` route removed.
- **GlobalPresenceState** ✅ — `@Observable @MainActor final class GlobalPresenceState`. Singleton. `refresh()` snapshots `GlobalAttentionCoordinator.shared.currentState`, `GlobalPresenceAggregator.shared.windowsPresence`, `anyDeviceHasUserPresent`, connected device count. `contextBlock() -> String` returns `[GLOBAL PRESENCE STATE]` block for LLM injection. `isAnyDeviceInCodingFlow`, `isAnyDeviceInMeeting`, `verbosityHint`, `interruptibilityScore` computed properties.
- **DistributedBrainDiagnostics additions** ✅ — `wsClientsConnected` (replaces `sseClientsConnected`), `replayFramesIngested`, `activeReplaySessions`. `recordReplayBegin/End/Frame()` methods.
- **pbxproj prefix** — `GL` (GlobalPresenceState.swift: GL01/GL02).

### Sprint P9 feature notes

**Entity Memory + Cross-Device Reference Resolution.** Adds a true semantic entity/reference layer so users can say "the other PR", "that button", "continue where we left off", "open it", etc. and Jarvis resolves them across devices, apps, conversations, and workflows.

**Core types (`EntityMemory/EntityMemoryModels.swift`)** ✅
- **`EntityMemKind`** — 23-case enum (pullRequest, githubIssue, branch, repo, file, uiElement, person, url, browserTab, window, task, codeSymbol, errorMessage, testCase, command, topic, calendarEvent, message, contact, obsidianNote, appleNote, entity, custom). Each case has `halfLifeSeconds` and `defaultExpiryPolicy`.
- **`ExpiryPolicy`** — `.ephemeral(300s)`, `.session(3600s)`, `.workflow(259200s/3d)`, `.persistent(2592000s/30d)`. Computed `maxAgeSeconds`.
- **`EntityMemSource`** — 11 cases: conversation, githubAPI, windowsPresence, ocrExtraction, ambientContext, userExplicit, proactiveEvent, workflowEngine, obsidianVault, appleNotes, systemEvent.
- **`EntityMemNode`** — `struct`, Identifiable + Codable. Fields: id, entityKind, canonicalName, aliases, source, expiryPolicy, salience, mentionCount, associatedUrls, associatedDevices, metadata, lastReferencedAt, lastMentionedAt, createdAt. Computed: `isExpired`, `currentRecencyScore() -> Double` (half-life decay: `pow(0.5, age/halfLife)`), `relevanceScore() -> Double` (`min(salience×0.5 + recency×0.4 + mentionBonus, 1.0)`).
- **`EntityMemRelationship`** — source/target id + kind string + confidence + createdAt. Codable.
- **`ResolutionResult`** — entity + confidence + source string + candidates array + `needsClarification: Bool` + `clarificationPrompt: String?`. Static `.empty`.
- **`ReferencePhrase`** / **`ReferencePhraseKind`** — detected reference categorized as: pronoun, recency, deictic, continual, crossDevice.

**`EntityMemoryGraph` (`EntityMemory/EntityMemoryGraph.swift`)** ✅ — `@MainActor final class`, singleton + isolated instances for tests.
- `upsert(_ node:)` merges by `(entityKind, canonicalName.lowercased())` — dedup, alias merge, association merge, mentionCount accumulation, metadata merge.
- `aliasIndex: [String: String]` for O(1) alias lookup. Rebuilt on `loadFromDisk()`.
- `all()`, `byKind(_ kind:limit:)`, `topSalient(limit:)`, `node(id:)`, `nodeForAlias(_ alias:)`.
- `prune()` — removes expired nodes, then evicts weakest by `relevanceScore()` until ≤500 nodes and ≤2000 relationships.
- 3-second debounced save to `~/Library/Application Support/JarvisMac/entity_memory.json`. `GraphPayload` struct: `schemaVersion: Int = 1`, nodes + relationships. Atomic write with `.atomicWrite`.

**`ConversationEntityExtractor` (`EntityMemory/ConversationEntityExtractor.swift`)** ✅ — `@MainActor final class`, singleton.
- `extract(from:source:deviceId:) -> [EntityMemNode]` — NLTagger NER + static regex patterns.
- `detectReferencePhrase(in:) -> ReferencePhrase?` — categorizes pronoun/recency/deictic/continual/crossDevice references.
- Static regex caches: `urlPattern`, `prPattern` (`PR #N` or `PR#N`), `issuePattern` (`Issue #N`), `filePattern` (common extensions).
- NLTagger `.nameType` scheme: `.personalName` → `.person` entity, `.organizationName` → `.entity`.

**`HybridEntityMatcher` (`EntityMemory/HybridEntityMatcher.swift`)** ✅ — `@MainActor enum`, static methods only.
- `bestMatch(phrase:in:kindFilter:) -> ResolutionResult` — 8-tier scoring: exact(1.0), aliasExact(0.97), prefix(0.75–0.90), aliasPrefix(0.70–0.85), contains(0.60), recency(0.55×), wordOverlap(0.45–0.70).
- `needsClarification` set when margin between top-2 < 0.15 AND confidence < 0.90.
- `mostRecentOf(kind:in:)` and `mostSalient(in:)` for pronoun resolution shortcuts.
- `minimumConfidence = 0.40`, `clarificationMargin = 0.15`.

**`EntitySalienceEngine` (`EntityMemory/EntitySalienceEngine.swift`)** ✅ — `@MainActor final class`, singleton.
- `recomputeAll(activeApp:activeUrls:)` — 5-dimension scoring: recency(0.40) + mentionFrequency(0.20) + appAlignment(0.20) + urlAlignment(0.10) + sourceTrust(0.10).
- `boost(id:)` — marks referenced + adds 0.15 salience (capped 1.0). Updates `lastReferencedAt`.
- `applyDecay()` — `node.salience × pow(0.5, age/halfLifeSeconds)` per node.

**`EntityLifecycleCoordinator` (`EntityMemory/EntityLifecycleCoordinator.swift`)** ✅ — `@MainActor final class`, singleton.
- `start()` subscribes to `SpeechCommandReceivedEvent` via SystemBus → `ingestSpeechCommand` → extract + upsert entities. Self-contained — zero JarvisController changes needed.
- `schedulePruneLoop()` — every 30 min: `applyDecay()` + `graph.prune()`.
- `ingestPresence(_ snapshot: PresenceSnapshot)` — creates `.file` (activeCodingFile), `.browserTab` (browserURL), `.window` (foregroundApp) nodes from Windows presence snapshots.
- `stop()` cancels prune loop Task + SystemBus subscription.

**`WorkflowContextResolver` (`EntityMemory/WorkflowContextResolver.swift`)** ✅ — `@MainActor enum`, static methods.
- `resolveWorkflowContinuation()` — priority order: PR → issue → task → file → topic.
- `resolveOther(kind:currentId:)` — returns second most-recent of same kind (skips currentId). Used for "the other PR" resolution.
- `workflowContextBlock() -> String?` — returns `{WORKFLOW CONTEXT}\nactive_repo: ...\nactive_branch: ...\n...` LLM block.

**`DistributedEntityLinker` (`EntityMemory/DistributedEntityLinker.swift`)** ✅ — `@MainActor final class`, singleton.
- `ingestPresence(_:)` delegates to `EntityLifecycleCoordinator` + cross-links window titles to known PR/issue entities in graph.
- `resolveWithDeviceBias(phrase:deviceId:) -> ResolutionResult` — returns entities associated with specific device, sorted by relevanceScore.
- `enrichEntity(id:deviceId:)` adds device association to existing node.

**`EntityContextBlockBuilder` (`EntityMemory/EntityContextBlockBuilder.swift`)** ✅ — `@MainActor enum`, static.
- `build(query:) -> String?` — top-8 nodes with salience ≥ 0.20, appends workflow block, appends disambiguation instruction.
- Output format: `[ENTITY MEMORY]\n# N known entities (top by salience)\nkind: name (url) [s=X.XX, r=X.XX]\n\n{WORKFLOW CONTEXT}\n...\n# Use these to resolve vague references: 'it', 'that', 'the other one'.`
- `buildReferenceLine(for:) -> String` — one-liner for disambiguation: `"kind: name, url=..., device=..."`.
- `explain(result:) -> String` — human-readable resolution explanation for diagnostics.

**`EntityMemoryDiagnostics` (`EntityMemory/EntityMemoryDiagnostics.swift`)** ✅ — `@Observable @MainActor final class`, singleton.
- Graph state: `totalNodes`, `expiredNodes`, `nodesByKind: [String: Int]`. `refresh()` reads from graph.
- Resolution stats: `resolutionsAttempted/Succeeded/Clarified/Failed`, `lastResolutionSource`, `lastResolutionConfidence`, `lastResolvedEntity`.
- `statusLine: String` — "N entities · X% resolved · last: EntityName".

**`DistributedReferenceResolver` update (`DistributedBrain/DistributedReferenceResolver.swift`)** ✅
- Added Tier 1: `entityResolve(_ normalized:) -> String?` before all existing presence heuristics.
- Dispatches by `ReferencePhrase.kind`: pronoun → `mostSalient`, recency → second-most-recent of kindHint, crossDevice → `DistributedEntityLinker.resolveWithDeviceBias`, continual → `WorkflowContextResolver.resolveWorkflowContinuation`, deictic → `mostRecentOf(kind:)`.
- Falls through to fuzzy match: `HybridEntityMatcher.bestMatch` threshold 0.72.
- All resolutions boost salience + record in `EntityMemoryDiagnostics`.
- `kindHint(from:)` maps "pr"→.pullRequest, "issue"→.githubIssue, "file"→.file, "tab"→.browserTab, "branch"→.branch, "task"→.task.
- Extended `enrichedContext` signals to include "the other", "continue", "again".

**Integration points** ✅
- **BrainRuntime** — `EntityMemoryGraph.shared.loadFromDisk()` + `EntityLifecycleCoordinator.shared.start()` in `start()`; `entityLifecycle?.stop()` in `stop()`.
- **MacBridgeProtocolV2** — `DistributedEntityLinker.shared.ingestPresence(snapshot)` called in `handlePresenceUpdate()`, so Windows presence data flows into the entity graph automatically.

**Type renames (collision avoidance)** ✅
- `EntityNode` → `EntityMemNode` (conflicts with `Entities/EntityGraph.swift` `struct EntityNode`)
- `EntityKind` → `EntityMemKind` (conflicts with `EntityGraph.EntityNode.EntityKind` nested enum)
- `EntityRelationship` → `EntityMemRelationship` (conflicts with `EntityGraph.swift` `struct EntityRelationship`)
- `Data.WritingOptions.atomic` → `.atomicWrite` (correct enum case name)

**Tests (`JarvisMacTests/EntityMemoryTests.swift`)** ✅ — 16 tests:
- Ephemeral node expiry (>300s → isExpired = true)
- Persistent node non-expiry (1 day → isExpired = false)
- Fresh node high recency score (>0.90)
- Stale node low recency score (<0.5 past halfLife)
- Upsert deduplication by (kind, canonicalName)
- Upsert alias merging across two upserts
- Alias index lookup by string
- Prune removes expired, keeps fresh
- Exact match → confidence 1.0, needsClarification = false
- Alias match → confidence ≥ 0.95
- Ambiguous prefix match margin check
- PR #N pattern extraction
- URL extraction
- resolveOther returns second most-recent
- Empty graph → topSalient empty
- pbxproj UUID regression (22 UUIDs checked exactly once)
- `makeIsolatedGraph()` returns fresh `EntityMemoryGraph()` (not `.shared`) for test isolation
- `EntityMemNode` extension: `withLastReferenced(_:)` / `withLastMentioned(_:)` for date backdating

**pbxproj prefixes** — `XE` (group `XE00A2B3C4D5E6F7A8B9CGRP`, path=EntityMemory); file prefixes: `XM` (EntityMemoryModels), `ZE` (EntityMemoryGraph — XG collision → renamed ZE), `XX` (ConversationEntityExtractor), `ZH` (HybridEntityMatcher — XH collision → renamed ZH), `XS` (EntitySalienceEngine), `XL` (EntityLifecycleCoordinator), `XW` (WorkflowContextResolver), `XD` (DistributedEntityLinker), `XB` (EntityContextBlockBuilder), `XY` (EntityMemoryDiagnostics) in main app; `XT` (EntityMemoryTests) in test target.

### Sprint HB1 — Heartbeat (living "current state" pulse)

Implements the vision's **Heartbeat** / Situation Room concept: a continuously-updated,
persisted, hot-reloadable snapshot of Jarvis's operational state (current focus, active
project + confidence, attention-needed, blockers, open issues, recent wins, today's
summary). It is a *living runtime layer* — editable on disk and reloaded without a restart.

- **`Heartbeat/HeartbeatModels.swift`** ✅ — `HeartbeatItem` (id, text, source, confidence, createdAt) and `HeartbeatState` (Codable, forward-compatible `decodeIfPresent` init). `contextBlock()` emits a `[HEARTBEAT — Jarvis live state]` block (only non-empty fields) for LLM injection. `situationSummary()` returns a short spoken status line.
- **`Heartbeat/HeartbeatStore.swift`** ✅ — `@Observable @MainActor` singleton. Persists to `~/Library/Application Support/JarvisMac/heartbeat.json` (atomic, 1.5s debounce). Hot-reloads on external edit via `DispatchSource` vnode watch (400ms debounce + 1s self-write echo guard). Bounded lists (attention 8, blockers 8, issues 12, wins 12) with case-insensitive dedup (refreshes timestamp instead of duplicating). Mutations: `setFocus`, `setActiveProject(_:confidence:)`, `setTodaySummary`, `recordInteraction`, `recordSessionStart`, `addAttention/Blocker/OpenIssue/Win`, `resolve(matching:)`, `clearAttention`, `reset`. `init(fileURL:)` for test isolation.
- **`Heartbeat/HeartbeatCoordinator.swift`** ✅ — `@MainActor` singleton. Self-contained: subscribes to SystemBus `IntentResolvedEvent` (→ focus + interaction), `ConversationStartedEvent` (→ session count), `ProactiveSignalGeneratedEvent` (priority ≥ .high → attention), `GitHubBuildFailedEvent` (→ open issue + blocker). 30s refresh loop pulls `ProjectRelationshipIndex.shared.activeFocusContext()` (≥0.40 → active project; <0.20 → clear) and `EpisodeStore.shared.todaysSummary()`. `humanizeIntent(_:)` turns `homeTurnOff`/`show_brain_overlay` into readable focus phrases.
- **Wiring** ✅ — `BrainRuntime.start()` calls `HeartbeatCoordinator.shared.start()` (mirrors `EntityLifecycleCoordinator`); `stop()` tears it down. `LLMFallbackHandler` injects `HeartbeatStore.shared.contextBlock()` right after the Brain-memory block (`[ContextInjection] source=heartbeat`).
- **No pbxproj surgery** — project is XcodeGen (`sources: - path: JarvisMac`), so new files under `JarvisMac/Heartbeat/` are auto-discovered on `make build`.
- **Tests** ✅ — `JarvisMacTests/HeartbeatTests.swift` (17 tests): item clamp, empty/populated context block, situation summary fallback + data, Codable round-trip, forward-compat partial decode, dedup, cap enforcement, cross-list resolve, confidence clamp, interaction recording, reset, intent humanization (camelCase / snake_case / associated-value strip).
