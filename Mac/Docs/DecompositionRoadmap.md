# JarvisController Decomposition Roadmap
*Sprint P — 2026-05-22*

## What Was Extracted (Phase 1 — Sprint N)

| File | Lines | Responsibility |
|------|-------|---------------|
| `Core/VisionEventBridge.swift` | 55 | Routes VisionModule motion/threat callbacks → ProactivityEngine |
| `Core/RuntimeBootstrapper.swift` | 40 | Registers 9 subsystem shells with RuntimeCoordinator and marks ready |
| `Core/GitHubIntegrationBootstrapper.swift` | 39 | Creates GitHubAPIClient + GitHubModule + optional proactivity provider |
| `Core/LLMFallbackHandler.swift` | 300 | Full LLM fallback flow: circuit guard, context assembly, routing, response handling |

**Sprint N reduction:** 8,422 → 8,161 lines (−261 lines, −3.1%)

---

## What Was Extracted (Phase 2 — Sprint O)

| File | Lines | Responsibility |
|------|-------|---------------|
| `Core/AndroidBridgeBootstrapper.swift` | 61 | WebSocket bridge + Tailscale bootstrap wiring |
| `Core/ProactivityProviderRegistry.swift` | 249 | ProactivityEngine callbacks, news wiring, all 7 proactivity providers, screen-error subscription |
| `Integrations/ShopifyIntentHandler.swift` | 105 | Shopify domain intents (pilot per-domain handler pattern) |

**Sprint O reduction:** 8,161 → 7,831 lines (−330 lines, −4.0%)

---

## JarvisController Remaining Responsibilities

After Phase 1, JarvisController still owns:
- Audio pipeline: wake word, STT, barge-in, microphone lifecycle
- `handleTranscript()` → phrase matching → intent routing chain
- `execute()` switch: all 74+ intent handlers (the largest remaining block)
- Conversational session state: `conversationalArmed`, `conversationalSessionActive`, follow-up timers
- TTS lifecycle: `speak()`, `speakingObserverTask`, `rewireSpeakingObserver()`
- Bootstrap: 650-line `bootstrap()` method wiring all subsystems
- Proactivity engine setup and notification queue
- Screen/camera awareness wiring
- All integration-specific `execute()` blocks: HA, Calendar, Todoist, Shopify, Spotify, Obsidian, Reddit, Android, etc.
- System control: volume, WiFi/BT, app management, clipboard
- Timer and stopwatch handlers
- Diagnostics: latency tracking, `state.log()`, breadcrumb writes

---

## Safe Future Extraction Candidates

Ranked by risk (lowest first):

### 1. AndroidBridgeBootstrapper (LOW RISK)
**Source:** Lines ~653–686 in bootstrap (WebSocket server + bridge + event receiver wiring)
**Size:** ~35 lines
**Dependencies:** `prefs`, `state`, `server`, `proactivity`, `context`
**Benefit:** Isolates WebSocket/Android setup; already has its own subsystem class

### 2. ProactivityProviderRegistry (LOW RISK)
**Source:** Lines ~990–1115 in bootstrap (weather/calendar/todoist/github/ha/shopify/obsidian providers)
**Size:** ~120 lines
**Dependencies:** `proactivity`, `state`, `prefs`, + each integration client
**Benefit:** All proactivity provider creation is today in one long if-else chain
**Risk:** Needs to return 7 stored provider vars back to JarvisController

### 3. IntentExecutionRouter (MEDIUM RISK)
**Source:** The 74-case `execute()` switch inside `handleTranscript()` (~4,000 lines, lines 2507–5700)
**Size:** This is not a single block — it's the majority of the remaining controller
**Approach:** Extract one MARK section at a time (GitHub, Shopify, Obsidian, etc.) into handler classes
**Risk:** Many cases call `speak()`, `openOverlay()`, `context.*`, `state.*` — all JarvisController APIs
**Strategy:** Extract leaf sections (GitHub, Shopify, Obsidian, Android calls) as standalone `executeXxx()` handler structs/classes with `speak` and `openOverlay` callbacks

### 4. ConversationalSessionCoordinator (MEDIUM RISK)
**Source:** Lines ~1775–2060 (`armConversationalMode()`, `handleWakeEvent()`, `handlePermanentSpeechFailure()`, watchdog, barge-in)
**Size:** ~285 lines
**Dependencies:** `state`, `conversation`, `prefs`, `tts`, `recognizer`, `wakeWord`
**Risk:** Tight coupling to `conversationalArmed`, `conversationalSessionActive` which are also read in `speak()` and `stopListening()`
**Approach:** Extract as a coordinator that gets callbacks for start/stop listening and reports state via published properties

### 5. TTSLifecycleManager (MEDIUM-HIGH RISK)
**Source:** `speak()`, `rewireSpeakingObserver()`, `stopSpeaking()`, `applyAddress()`
**Size:** ~180 lines
**Dependencies:** `tts`, `state`, `prefs`, `personality`, `renderer`, `conversation`
**Risk:** `speak()` is called from 200+ sites in JarvisController; refactoring the call sites is error-prone
**Approach:** Extract as a class but keep a `speak(_:)` proxy method on JarvisController

---

## Dangerous Extraction Zones

**Do NOT extract these:**

| Zone | Reason |
|------|--------|
| `handleTranscript()` function itself | Defines the entire pipeline; splitting it creates ordering fragility |
| `activePendingContext` management | Written by LLMFallbackHandler, ConversationRuntime, execute() cases, FollowUpResolver — any extraction must own it exclusively |
| `speak()` core method | Called from 200+ locations; interface changes cascade everywhere |
| ProactivityEngine internals | Self-contained subsystem — extraction would just move it |
| MemoryStore / SearchService | Already fully isolated — no extraction needed |
| SystemBus subscription block | Subscriptions must be stored by the subscriber; moving them creates dangling token risk |

---

## Systems That Should Remain Centralised

- **JarvisController.speak()** — the single TTS entry point with rate control, logging, address injection
- **JarvisController.execute()** — the single intent dispatch point; routing decisions live here
- **JarvisController.handleTranscript()** — the pipeline entry point; splitting it would break the trace flow
- **AppState** — shared observable UI state; not owned by any single subsystem
- **ConversationRuntime** — already extracted (Sprint H); JarvisController just holds and wires it

---

## What Was Extracted (Phase 3 — Sprint P)

| File | Lines | Responsibility |
|------|-------|---------------|
| `Integrations/SpotifyIntentHandler.swift` | 128 | All 8 Spotify execute() cases; owns lazy SpotifyAPIClient |
| `Integrations/WeatherIntentHandler.swift` | 42 | currentWeather + weatherForecast (async, location auth gate) |
| `Integrations/TodoistIntentHandler.swift` | 113 | showTasks, overdueTasks, addTask, completeTask (async + setPendingContext) |
| `Integrations/CalendarIntentHandler.swift` | 94 | showCalendar, nextMeeting, meetingsToday, addReminder (async + setPendingContext) |

**Sprint P reduction:** 7,831 → 7,607 lines (−224 lines, −2.9%)

---

## What Was Extracted (Phase 4 — Sprint Q)

| File | Lines | Responsibility |
|------|-------|---------------|
| `Integrations/HomeAssistantIntentHandler.swift` | 295 | All 20 HA execute() cases; owns statusSummary/entityLookup closures; closes/opens overlays |
| `Integrations/GitHubIntentHandler.swift` | 302 | All 23 GitHub execute() cases + `executeTask` helper (moved from JarvisController) |
| `Integrations/RedditIntentHandler.swift` | 308 | All 11 Reddit execute() cases + all Reddit helpers + `summariseText`; bridge typealias on JarvisController |

**Sprint Q reduction:** 7,607 → 6,892 lines (−715 lines, −9.4%)

---

## What Was Added (Sprint R — Audit & Tests)

Sprint R was a post-decomposition behavioural audit:
- `Docs/HandlerRouteMatrix.md` — 14-handler route matrix, 78 delegated intents documented
- 8 new test files in `JarvisMacTests/` covering all domain handlers
- `#if DEBUG` routing-gap detector added to `execute()` `.unknown` branch
- No routing gaps found; `RedditSummaryKind` typealias + bridge confirmed needed

---

## What Was Added (Sprint S — Unified Context Graph)

New subsystem: `JarvisMac/ContextGraph/` — additive, no existing code rewritten.

| File | Responsibility |
|------|---------------|
| `ContextGraph/ContextSource.swift` | `ContextSource` enum (13 cases) — where context originates |
| `ContextGraph/ContextNode.swift` | `ContextNode` struct, `ContextNodeType` (14 cases), `TrustTier` (Comparable) |
| `ContextGraph/ContextEdge.swift` | `ContextEdge` struct, `ContextEdgeType` (11 cases), dedup equality |
| `ContextGraph/ContextProvenance.swift` | `ProvenanceEntry`, `ContextProvenance` (budget-tracked), `ContextGraphDiagnostics` |
| `ContextGraph/ContextGraph.swift` | In-memory directed graph: externalID dedup, adjacency indices, O(1) neighbour lookup |
| `ContextGraph/ProjectRelationshipIndex.swift` | Query + ingestion layer: closure injection, thread/memory/note/trace ingestion, `activeContinuityChain`, `explainProvenance`, diagnostics |

`JarvisController` wires 4 source closures and fires an initial `refresh()` at boot.
`RuntimeDiagnosticsOverlayView` shows live node/edge/chain counts in the existing developer overlay.
`JarvisMacTests/ContextGraphTests.swift` — 12 tests covering dedup, edge merge, neighbours, provenance, diagnostics, TrustTier ordering.

---

## Architecture Target State

```
JarvisController (thin orchestration shell)
    ├── Bootstrap wiring delegates to bootstrappers
    ├── handleTranscript() → phrases → router → LLMFallbackHandler
    ├── execute() → delegates to per-domain IntentHandlers
    ├── speak() → TTSLifecycleManager
    └── Vision/GitHub/Android events → event bridges

Domain handlers (extracted over Sprints N–Q):
    ├── LLMFallbackHandler               ✅ Sprint N
    ├── VisionEventBridge                ✅ Sprint N
    ├── RuntimeBootstrapper              ✅ Sprint N
    ├── GitHubIntegrationBootstrapper    ✅ Sprint N
    ├── AndroidBridgeBootstrapper        ✅ Sprint O
    ├── ProactivityProviderRegistry      ✅ Sprint O
    ├── ShopifyIntentHandler             ✅ Sprint O (pilot)
    ├── SpotifyIntentHandler             ✅ Sprint P
    ├── WeatherIntentHandler             ✅ Sprint P
    ├── TodoistIntentHandler             ✅ Sprint P
    ├── CalendarIntentHandler            ✅ Sprint P
    ├── HomeAssistantIntentHandler       ✅ Sprint Q
    ├── GitHubIntentHandler              ✅ Sprint Q
    ├── RedditIntentHandler              ✅ Sprint Q
    └── ...
```
