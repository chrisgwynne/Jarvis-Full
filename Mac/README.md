# Jarvis — macOS AI Voice Assistant

> A cinematic, always-listening AI assistant for macOS. Voice-first, spatially aware, deeply integrated with your Mac and smart home.

---

## What Jarvis Can Do

| Category | Features |
|----------|---------|
| **Voice** | Always-on wake word ("Jarvis"), Apple Speech + Whisper STT, persistent conversational sessions, barge-in, partial-transcript fast routing |
| **AI / LLM** | MiniMax + LM Studio backends, memory injection, Obsidian RAG, personality system, multi-turn follow-ups, conversation summarisation |
| **Smart Home** | Home Assistant REST + WebSocket, 100+ entity types, rooms/scenes/automations, brightness/colour/covers/locks, real-time state-change proactivity |
| **Overlays** | 16 overlay kinds — Calendar, Tasks, News, Chat, GitHub, Shopify, Obsidian, Home, Camera, Memory, Notifications, Ambient Context, Runtime Diagnostics, and more |
| **Proactivity** | Calendar reminders, Todoist overdue, GitHub review requests, weather alerts, HA door/lock/smoke alerts, Shopify orders, Obsidian watch-tags |
| **Memory** | SQLite + FTS full-text search, NLEmbedding semantic index, hybrid search, conversation summariser, persistent preference store |
| **Spatial Interaction** | Hand-tracking HUD (pinch to open radial menu), dwell-click, orb hover ring, overlay drag/throw physics, two-hand resize, contextual menus |
| **Integrations** | Spotify, Shopify, Todoist, GitHub, Obsidian, EventKit, WeatherKit, NSPasteboard |
| **System** | File search, clipboard read/write, Wi-Fi/BT toggle, app launch/quit, window management, AppleScript runner |
| **Developer** | Debug HUD, Runtime Diagnostics overlay, Ambient Context overlay, ExecutionTrace pipeline, SystemBus typed pub/sub, EventStore ring buffer |

---

## Architecture

```
WakeWordService (Sherpa ONNX or Apple)
    │  wake event
    ▼
JarvisController.handleWakeEvent()  ──► SystemBus: WakeDetectedEvent
    │                                          ExecutionTracer.begin()
    ▼
SpeechRecognizer (Whisper or Apple Speech)
    │  transcript String
    ▼
ConversationRuntime.handleTranscript()
    │  armed session management, follow-up resolution
    ▼
CommandPhraseMatcher  →  IntentMapping  →  Intent?
    │  (Tier 1: exact/prefix/contains phrase matching)
    ▼
IntentRouter.route(parsed:)           (Tier 2: NLP parse + substring)
    │
    ▼
LLMIntentBridge → LLMRouter → MiniMax | LM Studio   (Tier 3: LLM fallback)
    │  Intent resolved
    ▼                       ┌─ Memory context
JarvisController.execute()  ├─ Obsidian RAG context
    │                       └─ Personality system prompt
    ├──► TextToSpeechService.speak()  (Apple AVSpeech or Piper)
    │         SystemBus: TTSStartedEvent / TTSFinishedEvent
    └──► OverlayManager.open(kind:)
              SystemBus: OverlayOpenedEvent
```

### Key Files

| File | Role |
|------|------|
| `Core/JarvisController.swift` | Orchestrator — owns all services, full wake→STT→intent→execute pipeline |
| `Core/ConversationRuntime.swift` | Persistent conversational session management, follow-up resolver |
| `Core/CommandModels.swift` | `Intent` enum (all cases), `AssistantPhase`, `OperatingMode` |
| `Core/AppState.swift` | `@Observable` UI state (phase, overlays, toast, diagnostics) |
| `Core/IntentRouter.swift` | Tier-2 substring + NLP routing |
| `Core/SystemBus.swift` | Typed pub/sub event bus — `subscribe<E: SystemEvent>`, `publish<E>` |
| `Core/SystemEventTypes.swift` | 28 concrete event structs (conversation, TTS, wake, overlay, app focus, …) |
| `Core/ExecutionTrace.swift` | Per-utterance pipeline trace with named steps + timing |
| `Core/RuntimeCoordinator.swift` | Ordered subsystem startup, health monitoring, isolated recovery |
| `Core/RuntimeDependencyGraph.swift` | Hard/soft dependency declarations, topological sort |
| `Core/ProactivityEngine.swift` | Signal ingestion, dedup, quiet hours, per-source toggles |
| `Phrases/CommandPhraseDefaults.swift` | ~1400 lines — all default phrases grouped by category |
| `Phrases/CommandPhraseMatcher.swift` | Tier-1 phrase matching |
| `UI/OverlaySystem.swift` | `OverlayKind` (16 kinds), `OverlayManager`, overlay host + panel views |
| `UI/CommandCentreView.swift` | Root view — orb stage, overlay host, toast, status strip, debug HUD |
| `Memory/SearchService.swift` | Hybrid FTS + semantic search |
| `Memory/SemanticMemoryIndex.swift` | NLEmbedding cosine similarity, 500-entry cap, persisted JSON |
| `Integrations/HomeAssistantRESTClient.swift` | HA REST API, fuzzy entity resolution, alias store |
| `Integrations/HomeAssistantWebSocketClient.swift` | HA WebSocket — auth, subscribe_events, state_changed |
| `Integrations/ObsidianVaultService.swift` | Incremental index, hybrid search, RAG context block |
| `SpatialInteraction/SpatialAmbientCoordinator.swift` | Hand-tracking state machine, HUD, drag physics, two-hand resize |
| `SpatialInteraction/SpatialInteractionView.swift` | `SpatialInteractionLayer` — orb hover ring, cursors, spread indicator |
| `SpatialInteraction/SpatialRadialHUD.swift` | Radial HUD chips with dwell-click arc |
| `SpatialInteraction/HandTrackingEngine.swift` | VNDetectHumanHandPoseRequest — primary + secondary hand |
| `Ambient/AmbientContextEngine.swift` | Passive app/screen awareness, 30s/8s sampling, privacy gate |
| `Ambient/PrivacyFilter.swift` | Blocks password managers, incognito windows |
| `Documentation/BuiltInContributors.swift` | In-app help articles for every feature |

---

## Requirements

- **macOS 13 Ventura** or later (macOS 14 Sonoma recommended)
- **Xcode 15+**
- Swift 5.9+

### Optional (for full feature set)

| Component | Install |
|-----------|---------|
| Sherpa-ONNX wake word | `Vendor/sherpa-onnx.xcframework` + model in `Models/sherpa-kws/` |
| Whisper STT | Swift Package: `https://github.com/ggerganov/whisper.cpp` + GGUF model |
| Piper TTS | Piper binary + ONNX voice model |
| `blueutil` | `brew install blueutil` (for Bluetooth toggle) |

---

## Quick Start

```bash
git clone https://github.com/christopherwxyz/jarvis.git
cd jarvis
open JarvisMac.xcodeproj    # or xcodegen generate first if needed
# ⌘R to build and run
```

Jarvis runs as a **status-bar app** with a floating Command Centre window. On first launch it uses Apple Speech + Apple TTS with no configuration required.

---

## Configuration

All settings live in **⌘,** (Preferences) and persist to `~/Library/Application Support/JarvisMac/preferences.json`.

### API Tokens

| Setting | Where to get it |
|---------|----------------|
| Home Assistant URL + token | HA → Profile → Security → Long-lived access tokens |
| Todoist API token | Todoist → Settings → Integrations → API token |
| GitHub PAT | GitHub → Settings → Developer settings → PATs (`notifications` scope) |
| Shopify access token | Shopify → Apps → Develop apps → Admin API access token |
| Spotify personal token | Spotify OAuth Playground — scopes: `user-read-playback-state user-modify-playback-state` |
| MiniMax base URL | Your MiniMax API endpoint |
| LM Studio base URL | `http://localhost:1234` (default) |
| Obsidian vault path | Absolute path to your vault folder |

### Wake Word Setup (Sherpa-ONNX)

1. Download `sherpa-onnx.xcframework` from [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases)
2. Place at `Vendor/sherpa-onnx.xcframework`
3. Download a KWS model (e.g. `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01`)
4. Extract to `Models/sherpa-kws/`
5. ⌘, → **Voice** → point model directory + keywords file at your model

### Whisper STT Setup

1. File → Add Package Dependencies → `https://github.com/ggerganov/whisper.cpp`
2. Download a model (e.g. `ggml-base.en.bin`) from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp)
3. ⌘, → **Voice** → set Speech engine to *Whisper* + model path

---

## Voice Command Reference

### System & App Control
| Say | What happens |
|-----|-------------|
| "Jarvis" | Wake (if always-on wake word) |
| "open [app name]" | Launch or focus the app |
| "quit [app name]" | Quit the app |
| "search for [query]" | Spotlight / file search |
| "copy / paste / undo" | Keyboard shortcut dispatch |
| "turn on Wi-Fi / Bluetooth" | Toggle via networksetup / blueutil |
| "read my clipboard" | Speaks clipboard contents |
| "copy [text]" | Writes text to clipboard |

### Timers & Reminders
| Say | What happens |
|-----|-------------|
| "set a timer for 5 minutes" | Named countdown timer |
| "set a [name] timer for 10 minutes" | Named timer ("pasta", "meeting", …) |
| "how long left on the timer" | Speaks remaining time |
| "cancel the timer" | Cancels active timer |
| "start a stopwatch" | Starts stopwatch |
| "remind me to [task] in 30 minutes" | EventKit reminder |

### Calendar & Tasks
| Say | What happens |
|-----|-------------|
| "what's on my calendar today" | Speaks today's events |
| "what's my next meeting" | Next upcoming event |
| "show my calendar" | Opens Calendar overlay |
| "add event [title] tomorrow at 3pm" | Creates EventKit event |
| "what are my tasks" | Reads Todoist tasks |
| "show my tasks" | Opens Tasks overlay |
| "add task [title]" | Creates Todoist task |
| "mark [task] done" | Closes matching Todoist task |

### Weather
| Say | What happens |
|-----|-------------|
| "what's the weather" | Current conditions (WeatherKit) |
| "what's the forecast" | 5-day forecast |
| "will it rain tomorrow" | Yes/no rain prediction |

### Smart Home
| Say | What happens |
|-----|-------------|
| "turn on / off the [device]" | HA entity toggle |
| "set [light] to 50 percent" | Brightness control |
| "set [light] to warm white" | Colour temperature |
| "what's the temperature in [room]" | Climate sensor read |
| "lock / unlock the [door]" | Lock entity control |
| "run the [automation]" | HA automation trigger |
| "home status" / "show home panel" | Opens Home overlay |

### Spotify
| Say | What happens |
|-----|-------------|
| "play / pause music" | Playback toggle |
| "next / previous song" | Track navigation |
| "shuffle on / off" | Shuffle toggle |
| "set volume to 60" | Volume control |
| "what's playing" | Speaks current track + artist |

### Obsidian
| Say | What happens |
|-----|-------------|
| "search my notes for [query]" | Hybrid FTS + semantic search |
| "show my notes" | Opens Obsidian overlay |
| "create a note [title]" | New note with Jarvis frontmatter |
| "append to [note] [text]" | Timestamped append |

### GitHub
| Say | What happens |
|-----|-------------|
| "check GitHub" | Reads notification summary |
| "show GitHub" | Opens GitHub overlay |

### Shopify
| Say | What happens |
|-----|-------------|
| "check my orders" | Recent order count + revenue |
| "today's revenue" | Speaks today's total |
| "show my store" | Opens Shopify overlay |

### Screen & Vision
| Say | What happens |
|-----|-------------|
| "what can you see" | Describes camera frame |
| "read this" | OCR on camera frame |
| "what am I working on" | Reads active app context |
| "what failed on screen" | Reads detected errors |
| "watch this" | Activates watch mode (8s sampling) |
| "stop watching" | Deactivates watch mode |

### Memory & AI
| Say | What happens |
|-----|-------------|
| "remember that [fact]" | Stores to memory |
| "what do you remember about [topic]" | Hybrid memory search |
| "forget everything about [topic]" | Deletes matching memories |
| "summarise our conversation" | LLM-compresses session |
| "[anything else]" | LLM fallback with memory + vault context |

### Overlays & Interface
| Say | What happens |
|-----|-------------|
| "show news" | Opens News overlay |
| "open chat" | Opens Chat overlay |
| "show notifications" | Opens Notifications tray |
| "show ambient context" | Opens Ambient Context debug overlay |
| "runtime diagnostics" | Opens Runtime Diagnostics overlay |
| "close that" / "dismiss" | Closes top overlay |
| "pin that" / "unpin that" | Pins overlay so close doesn't dismiss it |
| "developer mode" | Toggles Debug HUD |

### Conversational
| Say | What happens |
|-----|-------------|
| "stop listening" / "go quiet" | Mutes Jarvis (ends session) |
| "stop talking" | Cancels current TTS |
| "yes" / "no" | Resolves active follow-up question |
| "never mind" | Clears pending follow-up |

---

## Spatial Interaction

Jarvis includes a full hand-tracking system using the Mac's built-in camera. **No additional hardware required.**

### How It Works

1. **Hand detection** — `VNDetectHumanHandPoseRequest` processes frames from `CameraManager` (adaptive FPS: ~5fps idle → 60fps active)
2. **Presence states** — `noHand` → `handDetected` → `pinchActive` → `hudOpen`
3. **Orb hover ring** — A pulsing cyan ring appears around the orb when your cursor approaches

### Radial HUD

Pinch in space (index + thumb together) to open a 6-item radial menu arranged in a 180° arc above the pinch point.

**Default items (no overlay focused):**

| Icon | Action |
|------|--------|
| newspaper | Open News |
| camera | Open Camera |
| brain | Open Memory |
| stethoscope | Open Diagnostics |
| xmark | Close Overlay |
| arrow.counterclockwise | Reset View |

**Overlay-focused items:**

| Icon | Action |
|------|--------|
| newspaper | Open News |
| camera | Open Camera |
| brain | Open Memory |
| pin | Pin/Unpin Overlay |
| arrow.up.left.and.arrow.down.right | Maximize Overlay |
| xmark | Close Overlay |

### Dwell-Click

Hover your fingertip over any HUD chip for **1.5 seconds** — a cyan arc fills around the chip and it auto-fires. No physical click needed.

### Pinch-to-Drag

Pinch **inside** an overlay panel to drag it anywhere on screen. Release to drop. Fling with velocity (> 300 pt/s) to throw the panel — it coasts to a stop with physics.

### Overlay Hover Glow

When your hand is detected, hovering near an overlay panel highlights it with a cyan gradient border + glow. The nearest panel highlights automatically.

### Two-Hand Resize

Raise a **second hand** while an overlay is focused. The spread distance between your index fingertips controls the overlay width — spread to expand, pinch to shrink.

### Diagnostics

Say "spatial diagnostics" or use the `SpatialDiagnosticsOverlay` (visible in the `SpatialInteractionLayer` when enabled) to see live hand pose data, FPS, and gesture state.

---

## Proactivity Engine

Jarvis monitors external sources and announces relevant information without being asked.

### Signal Sources

| Source | What it watches | Default cadence |
|--------|----------------|-----------------|
| Calendar | 10-min + 1-min event reminders | EventKit poll every 60s |
| Todoist | Overdue tasks, morning briefing | Poll every 5min |
| GitHub | Review requests, mentions, assignments | Poll every 10min |
| Weather | Morning briefing 7–8am, severe weather, rain | Poll every 15min |
| Home Assistant | Door/lock/motion/smoke/vacuum state changes | WebSocket real-time |
| Shopify | New orders, low stock (< threshold) | Poll every 5min |
| Obsidian | Watch-tag notes (`#jarvis`, `#review`, `#urgent`), recently modified | Poll every 5min |

### Quiet Hours

Proactivity pauses automatically during configured quiet hours. Smoke/CO alerts bypass quiet hours.

### Proactivity API

```swift
engine.ingest(signal, appState: appState)   // thread-safe, @MainActor
engine.pause() / engine.resume()
engine.dismiss(signalId)
engine.mute(.calendar, for: 3600)           // mute for 1 hour
engine.settings.githubEnabled = false       // per-source toggle
```

---

## Overlay System

16 overlay kinds, each with its own view, size, accent colour, and voice trigger.

| Kind | View | Default Size | Accent |
|------|------|-------------|--------|
| `.news` | `NewsOverlayView` | large | cyan |
| `.camera` | `CameraPreviewWidget` | cinema | purple |
| `.calendar` | `CalendarOverlayView` | large | blue |
| `.tasks` | `TasksOverlayView` | large | green |
| `.memory` | memory browser | medium | indigo |
| `.chat` | `ChatOverlayView` | large | cyan |
| `.timeline` | `TimelineOverlayView` | large | orange |
| `.notifications` | `NotificationTrayView` | medium | orange |
| `.article` | WKWebView | large | white |
| `.home` | `HomeOverlayView` | large | orange |
| `.shopify` | `ShopifyOverlayView` | large | green |
| `.github` | `GitHubOverlayView` | large | white |
| `.obsidian` | `ObsidianOverlayView` | large | purple |
| `.ambientContext` | `AmbientContextOverlayView` | compact | teal |
| `.runtimeDiagnostics` | `RuntimeDiagnosticsOverlayView` | medium | indigo |
| `.proactiveAlert` | generic alert card | compact | orange |

Overlays can be **pinned** (not closed by "close that"), **stacked** (multiple open), and **manually positioned** via pinch-to-drag.

---

## LLM Integration

Jarvis uses a three-tier intent resolution system:

1. **Tier 1** — `CommandPhraseMatcher`: exact/prefix/contains phrase matching against `CommandPhraseStore`
2. **Tier 2** — `IntentRouter`: NLP parse (`CommandUnderstanding`) + substring routing
3. **Tier 3** — `LLMIntentBridge` → `LLMRouter`: MiniMax or LM Studio backend

### Context Injection (Tier 3)

Every LLM call receives:
- **Personality system prompt** — built from `PersonalityContextBuilder` (name, formality, humour, honorific)
- **Memory context** — top-3 relevant memories from `hybridSearch`
- **Obsidian RAG context** — top-N vault notes matching the query (when `obsidianLLMContextEnabled`)

### Streaming

Partial transcripts with ≥ 3 words and ≥ 0.92 confidence trigger early STT exit via `FastResponseRouter`, cutting perceived latency.

---

## Memory System

| Component | Description |
|-----------|-------------|
| `MemoryStore` | CRUD SQLite via GRDB — stores facts, conversation summaries, user preferences |
| `SearchService` | Hybrid FTS + semantic search, deduplicated, ranked |
| `SemanticMemoryIndex` | `NLEmbedding.sentenceEmbedding` cosine similarity, 500-entry cap, persisted JSON |
| `ConversationSummariser` | LLM-compresses last 20 turns into MemoryStore (fires on session end + daily) |
| `PreferencesStore` | Typed `Preferences` struct, JSON-persisted, `decodeIfPresent` upgrade-safe |

---

## Runtime Architecture

### Subsystems (startup order)

| Order | Runtime | Depends on |
|-------|---------|-----------|
| 10 | SystemRuntime | — |
| 20 | MemoryRuntime | system |
| 30 | AudioRuntime | system |
| 40 | ConversationRuntime | audio, system |
| 50 | OverlayRuntime | system |
| 60 | AmbientRuntime | system, overlay |
| 70 | LLMRuntime | system, memory |
| 80 | ProactivityRuntime | system, overlay, conversation |
| 90 | AndroidRuntime | system |

`RuntimeCoordinator.shared` starts subsystems in order, polls health every 30s, and recovers failed subsystems independently (max 3 retries).

### SystemBus Events (28 types)

App focus, screen context, overlay open/close, conversation lifecycle (started/ended/timed-out/follow-up), wake detected, listening started/stopped, TTS started/finished, intent resolved, memory updated, proactive signal generated, and more.

### ExecutionTrace

Every wake-word utterance gets a `UUID` correlation ID. The pipeline adds named steps (`listening`, `transcript`, `intent_resolved`, `tts`) with timestamps. Last 50 traces available via `ExecutionTracer.shared.recentTraces(limit:)`.

---

## Developer Tools

### Debug HUD (⌘⇧D)

Live diagnostics overlay — phase, session state, proactivity signals, conversation armed state, restart count.

### Ambient Context Overlay

Say "show ambient context". Shows active app, window title, latest screen OCR summary, detected errors, watch mode state, recent SystemBus events colour-coded by category.

### Runtime Diagnostics Overlay

Say "runtime diagnostics". Shows all 9 subsystem states + restart counts, EventStore throughput bar chart (60s window), current TaskThread. Auto-refreshes every 2s.

### In-App Help

Say "help" or "what can you do" — opens the documentation overlay with articles for every feature area, written by `BuiltInContributors`.

---

## Project Layout

```
JarvisMac/
├── App/                    @main, scenes, menu commands
├── Core/                   JarvisController, AppState, IntentRouter,
│                           CommandModels, SystemBus, SystemEventTypes,
│                           ConversationRuntime, ExecutionTrace,
│                           RuntimeCoordinator, RuntimeDependencyGraph,
│                           ProactivityEngine, ProactivitySignal, TimerService
├── Audio/                  TextToSpeechService, PiperTTS, SpeechRecognizer,
│                           WakeWordService, SherpaWakeWord, BargeInMonitor
├── Ambient/                AmbientContextEngine, ActiveAppMonitor,
│                           WindowContextMonitor, AmbientContextModels,
│                           PrivacyFilter
├── SpatialInteraction/     HandTrackingEngine, SpatialAmbientCoordinator,
│                           SpatialInteractionView, SpatialRadialHUD
├── Phrases/                CommandPhraseDefaults, CommandPhraseStore,
│                           CommandPhraseMatcher, IntentMapping
├── NLP/                    CommandUnderstanding, UnmatchedCommandStore
├── Responses/              ResponseTemplate, ResponsePlaybook,
│                           ResponseTemplateStore, ResponseRenderer
├── Memory/                 PreferencesStore, JarvisDatabase, MemoryStore,
│                           SearchService, SemanticMemoryIndex,
│                           ConversationSummariser
├── Integrations/           HomeAssistantRESTClient, HomeAssistantWebSocketClient,
│                           SmartHomeClient, HomeEntityAliasStore,
│                           EventKitCalendarService, TodoistAPIClient,
│                           WeatherService, GitHubAPIClient, SpotifyAPIClient,
│                           ShopifyAPIClient, ObsidianNote, ObsidianVaultService,
│                           *ProactivityProvider (8 providers)
├── UI/                     CommandCentreView, OverlaySystem, OrbView,
│                           BlueprintBackgroundView, SettingsView,
│                           CalendarOverlayView, TasksOverlayView,
│                           HomeOverlayView, GitHubOverlayView,
│                           ShopifyOverlayView, ObsidianOverlayView,
│                           AmbientContextOverlayView,
│                           RuntimeDiagnosticsOverlayView, DebugHUDView,
│                           FileSearchOverlayView, ChatOverlayView
├── Documentation/          BuiltInContributors, HelpContributor protocol
├── Actions/                MacSystemController, AppleScriptRunner
├── Networking/             AndroidBridge, WebSocketServer
└── Resources/              Info.plist, entitlements, Assets.xcassets

Vendor/                     Drop sherpa-onnx.xcframework here (gitignored)
Models/                     Drop sherpa-kws/, whisper-*.bin here (gitignored)
```

---

## Permissions

macOS prompts the first time each capability is used. All denials are non-fatal — the relevant feature degrades gracefully.

| Permission | Used for |
|-----------|---------|
| Microphone | Wake word, STT, barge-in |
| Camera | Hand tracking, vision, OCR |
| Speech Recognition | Apple Speech engine |
| Contacts / Calendar | EventKit calendar + reminders |
| Local Network | Android WebSocket bridge |
| Apple Events | AppleScript automation |
| Automation | App control via System Events |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧D` | Toggle Debug HUD |
| `⌘⇧L` | Toggle listening |
| `⌘,` | Open Settings |

---

## Roadmap

### Near-term (next sprint)

- **Email integration (A2)** — Apple Mail AppleScript, VIP + keyword proactivity provider, read/summarise/reply intents
- **Apple Notes (A12)** — Create notes via `tell application "Notes"`, search, append
- **Keychain migration** — Move 5 API tokens (HA, Todoist, GitHub, Shopify, Spotify) from preferences.json to macOS Keychain
- **LLM context gates** — `llmSendsScreenContext` / `llmSendsCameraContext` prefs before injecting screen/camera into LLM calls

### Medium-term

- **Continuous ambient vision (A6)** — `AmbientVisionService`, background camera frame analysis at configurable cadence, event-driven proactivity from screen state
- **Window management (A11)** — `AXUIElement` position/size/tiling, multi-display awareness, voice-directed window choreography
- **Gesture control (A5)** — Full `VNDetectHumanHandPoseRequest` gesture vocabulary: palm-push to dismiss, point-to-focus, spread-to-scroll

### Long-term

- **A7 — Unified fullscreen stage** — Transparent `NSWindow` layer owning the full display; overlays rendered as spatial panels in 3D space
- **On-device LLM** — Core ML / MLX inference for fully local, privacy-first AI responses
- **Multi-display awareness** — Jarvis orb and overlays follow focus across screens
- **iOS / visionOS companion** — Shared intent model, iCloud-synced memories, cross-device handoff
- **Plugin system** — Swift package-based contributors for custom overlays, intents, and proactivity providers
- **Hardened runtime + App Store distribution** — Sandbox entitlements, notarisation, MAS review

---

## Sprint History

| Sprint | Key additions |
|--------|--------------|
| **Phase 1** | Push-to-talk, AVSpeech TTS, USB webcam, fullscreen dashboard, intent router, WebSocket server |
| **Phase 2** | Sherpa-ONNX wake word, Whisper STT, barge-in, Apple Vision OCR/motion, HA REST, ContextEngine, latency tracking |
| **Sprint A** | HA extended (brightness/colour/scenes/covers/locks), Calendar (EventKit), Todoist, ResponseRenderer, ProactivityEngine, News, LLM layer, Memory, Personalities, ~50 new response keys |
| **Sprint B** | WeatherKit, proactivity providers (Calendar/Todoist/GitHub), CalendarOverlayView, TasksOverlayView, HomeEntityAliasStore, UnmatchedCommandsView, daily briefing, help system |
| **Sprint C** | Multi-turn conversations, memory→LLM injection, streaming fast-path, WeatherProactivity, personality depth, wake watchdog, dual camera, pinnable overlays, GitHub overlay, Wi-Fi/BT, HA automations |
| **Sprint D** | HA WebSocket proactivity (real-time), Shopify (API+overlay+proactivity), HomeOverlayView (room grid), TimerService (multi-timer+stopwatch), clipboard, Spotify, ConversationSummariser, SemanticMemoryIndex |
| **Sprint E** | Obsidian vault (ObsidianNote, ObsidianVaultService incremental index + hybrid search + RAG, ObsidianProactivityProvider, ObsidianOverlayView, 9 new intents, Settings tab) |
| **Sprint F** | SystemBus typed pub/sub, 16 SystemEvent structs, AmbientContextEngine (passive app/screen awareness), ActiveAppMonitor, WindowContextMonitor, PrivacyFilter, AmbientContextModels, AmbientContextOverlayView, watch mode |
| **Sprint G** | RuntimeSubsystem protocol + RuntimeCoordinator (ordered startup, health monitor, recovery), RuntimeRegistry (9 shell conformances), EventStore (1000-event ring buffer), TaskThreadEngine, AppContextAdapter (Cursor/Xcode/Terminal/Safari), ContextConfidence, RuntimeDiagnosticsOverlayView |
| **Sprint H** | ConversationRuntime (real class — owns all session state + callbacks + SystemBus events), ExecutionTrace (per-utterance pipeline tracing), RuntimeDependencyGraph (topological sort), 12 new SystemBus event types, ProactivityEngine SystemBus integration, full event publishing in JarvisController |
| **Sprint I** | Spatial interaction expansion: orb hover ring, overlay spatial focus glow, pinch-to-drag, throw physics (velocity-based fling), two-hand resize, contextual HUD (default vs overlay-focused), dwell-click (1.5s arc auto-fire), two-hand pose tracking (maximumHandCount=2), SpatialInteractionContributor help article |

---

## Caveats

- **Sherpa-ONNX and Whisper models** are large (50–300 MB) and gitignored — do not check them in
- **blueutil** is required for Bluetooth toggle (`brew install blueutil`); without it the command opens System Settings as a fallback
- **WeatherKit** requires the WeatherKit capability in Xcode (not just the framework) and a device with location permission
- **Spotify** uses a personal OAuth token from the Spotify developer OAuth Playground — tokens expire and must be refreshed manually
- **Hand tracking** uses the Mac's built-in camera. If another app (e.g. FaceTime) is using the camera, hand tracking will not start. The primary camera is shared with Jarvis's vision features
- **WebSocket server** binds to all interfaces by default — use a shared-secret token (`requireWebSocketAuth = true`) on any non-trusted LAN
- **Hardened runtime is OFF** for local development — enable before any App Store distribution

---

*Built with Swift, SwiftUI, AVFoundation, Vision, NaturalLanguage, EventKit, WeatherKit, and a lot of voice commands.*
