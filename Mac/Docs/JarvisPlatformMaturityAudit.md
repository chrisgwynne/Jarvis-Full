# Jarvis macOS — Platform Maturity Audit

**Audit date:** 2026-05-22  
**Auditor:** Claude Sonnet 4.6 (full-codebase static trace, no assumptions)  
**Method:** Every Swift file read. Execution paths traced from wake event through to output. File existence alone was never treated as evidence of functionality.  
**Scope:** 358 Swift files across 28 directories, ~8 400-line JarvisController god class, all integrations, all subsystems, all Sprint commits through Sprint L.

---

## 1. Platform Classification

Jarvis is a **macOS-native voice-first personal operating assistant** with the following genuine capabilities as of this audit:

- Real-time voice command execution via wake word → STT → intent pipeline
- Multi-turn conversational sessions with follow-up resolution
- Smart home control (Home Assistant REST + WebSocket)
- Calendar, task, weather, GitHub, Shopify, Spotify, Obsidian integrations
- Proactive ambient intelligence (8 providers, sophisticated filtering)
- Computer vision surveillance with threat heuristics (single-camera + RTSP)
- Hand-gesture interaction (pinch/drag/spread/hold) for overlay control
- LLM fallback with RAG (memory + Obsidian vault + vision context)
- Event-driven runtime substrate (SystemBus, RuntimeCoordinator, EventStore)
- Living documentation system

**Classification:** Late-prototype / early production. Core voice pipeline is solid. Several architectural subsystems exist but contain integration gaps that prevent them from running in production as designed.

---

## 2. Implementation Maturity Scores

Scores are 1–10 based on: real execution paths exist, error handling present, no silent no-ops, production-quality state management.

| Subsystem | Score | Confidence | Notes |
|---|---|---|---|
| Voice pipeline (wake→STT→intent→TTS) | 9 | High | Fully traced. Watchdog, barge-in, ConversationRuntime all wired. |
| Intent routing (phrase matcher + router) | 8 | High | 5 match types, 2305-line IntentRouter, regex timers, dual-path structured parse. One gap: regex patterns compiled per-call not static. |
| ConversationRuntime / session management | 8 | High | Separate class, 244 lines, properly wired. arm/timeout/restart paths all exist. |
| LLM routing (MiniMax/Gemini/LMStudio) | 7 | High | Circuit breaker, streaming, fallback chain real. Gemini timeout edge case noted below. |
| Memory system (SQLite + semantic) | 7 | High | hybridSearch real. SemanticMemoryIndex with NLEmbedding real. LLM injection real. |
| ProactivityEngine | 8 | High | decide() fully implemented: quiet hours, daily caps, cooldowns, dedup, per-source toggles, auto-pause on follow-up. |
| Home Assistant integration | 8 | High | REST + WebSocket. Entity cache, alias store, fuzzy resolution. WS ping/pong present. |
| GitHub integration (Sprint J) | 6 | High | 9 sub-managers real. Code review LLM wired as nil — heuristic only in production. |
| Obsidian vault (Sprint E) | 8 | High | Incremental index, hybrid FTS+semantic, RAG injection, create/append all real. |
| Vision / surveillance (Sprint L) | 6 | Medium | Pipeline real (VN requests). Threat classifier is pure heuristic — no CoreML model. YOLOv8 optional, not bundled. |
| Spatial gesture system | 7 | High | Hand pose request + dominant lock + gesture state machine real. HUD → overlay wiring real. |
| SystemBus | 9 | High | Typed pub/sub, 200-event ring buffer, recursion guard, catch-all — all implemented. |
| RuntimeCoordinator | 5 | High | Health polling works. Critical gap: never calls start() on registered subsystems. |
| EventStore | 2 | High | Class exists and is correct. Never started in production. Ring buffer never fills. |
| RuntimeRegistry shells | 3 | High | 8 shells exist. Only SystemRuntime.start() does anything (starts EventStore if called — it isn't). |
| ConversationRouter (Sprint K) | 7 | High | O(n) string matching, 5 routes, confidence gating, conservative defaults. |
| Ambient context engine | 7 | High | ActiveAppMonitor, WindowContextMonitor, PrivacyFilter, watch mode — all real. |
| Android bridge | 6 | Medium | WebSocket + correlated request/response real. Usage paths from JarvisController limited. |
| Keychain / security | 8 | High | Real Security framework. 8 accounts. Migration path with plaintext fallback. |
| Overlay system | 8 | High | 25 kinds, pinnable, resize, proper SwiftUI wiring. Not all views implemented (see §3). |

---

## 3. Full Feature Matrix

### Voice & Speech
| Feature | Status | Notes |
|---|---|---|
| Wake word detection (Apple) | Implemented | SFSpeechRecognizer-based |
| Wake word detection (Sherpa ONNX) | Implemented | Model path configurable |
| Apple Speech STT | Implemented | |
| Whisper STT | Implemented | Local GGUF model |
| Barge-in (interrupt TTS with wake) | Implemented | bargeInEnabled pref, properly doesn't clear session |
| Piper TTS | Implemented | Needs external executable + ONNX model |
| AVSpeech TTS | Implemented | Default |
| Persistent conversational session (10 min) | Implemented | ConversationRuntime.arm() |
| Silence timeout → restart STT | Implemented | endSession(permanent:false) + 150ms restart |
| Inactivity watchdog | Implemented | wakeWatchdogTick() 60s poll |
| Partial transcript fast-routing | Implemented | FastResponseRouter, confidence ≥0.92 early exit |

### Intent & Routing
| Feature | Status | Notes |
|---|---|---|
| Exact phrase match | Implemented | |
| Prefix phrase match | Implemented | |
| Contains phrase match | Implemented | |
| Regex phrase match | Implemented | |
| Fuzzy (Levenshtein) phrase match | Implemented | threshold 0.80 |
| Near-miss recording | Implemented | 0.55–0.80 confidence band |
| Structured NLP parse (action+target+label) | Implemented | CommandUnderstanding.swift |
| Substring fallback routing | Implemented | IntentRouter.route(_:), 2305 lines |
| LLM fallback | Implemented | tryLLMFallback() |
| Follow-up resolution | Implemented | FollowUpResolver, 189 lines, yesNo/clarification/choice/freeform |
| Contextual pronoun resolution | Implemented | "open that", "close that", "summarise that" |
| Unmatched command learning | Implemented | UnmatchedCommandStore, frequency badges, LLM hint |
| ConversationRouter multi-lane (Sprint K) | Implemented | 5 routes, confidence short-circuit |

### Smart Home
| Feature | Status | Notes |
|---|---|---|
| HA light on/off/dim/colour/scene | Implemented | |
| HA switch/cover/lock control | Implemented | |
| HA automation trigger | Implemented | |
| Entity alias store | Implemented | persisted JSON |
| Fuzzy entity resolution | Implemented | resolveEntity(matching:) |
| HA WebSocket proactivity | Implemented | door/lock/motion/smoke/offline/vacuum alerts |
| Smoke/CO bypass quiet hours | Implemented | |

### Calendar & Tasks
| Feature | Status | Notes |
|---|---|---|
| EventKit today/next event | Implemented | |
| EventKit add reminder | Implemented | |
| Todoist get/create/close tasks | Implemented | REST v2 |
| Calendar overlay view | Implemented | |
| Tasks overlay view | Implemented | |
| Calendar proactivity (10min + 1min alerts) | Implemented | |
| Todoist morning overdue | Implemented | |

### Weather
| Feature | Status | Notes |
|---|---|---|
| Current weather (WeatherKit) | Implemented | |
| Forecast (days) | Implemented | |
| Rain warning | Implemented | |
| Weather proactivity (morning/severe/rain) | Implemented | |

### GitHub (Sprint J)
| Feature | Status | Notes |
|---|---|---|
| Notifications fetch | Implemented | paginated, rate-limit aware |
| GitHub overlay view | Implemented | 4 sections |
| Voice intent routing | Implemented | GitHubVoiceIntentRouter, 20+ intents |
| PR review (heuristic) | Implemented | size/complexity/review count |
| PR review (LLM summary) | Wired but disabled | llmRouter=nil in JarvisController bootstrap |
| GitHub proactivity | Implemented | review requests, mentions, assignments |
| CI/build status | Implemented | GitHub Actions API |
| Repository explorer | Implemented | |
| Living issue tracker | Implemented | |
| Code search | Implemented | |
| Commit analysis | Implemented | |
| Roadmap tracker | Implemented | |
| Collaboration insights | Implemented | |

### Shopify
| Feature | Status | Notes |
|---|---|---|
| Recent orders / revenue | Implemented | |
| Low stock alerts | Implemented | |
| Shopify overlay view | Implemented | |
| Shopify proactivity | Implemented | |

### Spotify
| Feature | Status | Notes |
|---|---|---|
| Play/pause/next/previous | Implemented | |
| Shuffle/volume | Implemented | |
| Now playing | Implemented | |
| Personal token (no OAuth server) | Implemented | |

### Obsidian (Sprint E)
| Feature | Status | Notes |
|---|---|---|
| Vault indexing (incremental, 2min poll) | Implemented | |
| Hybrid FTS + semantic search | Implemented | |
| RAG injection into LLM | Implemented | contextForLLM() |
| Create / append notes by voice | Implemented | |
| Obsidian overlay (browser + detail pane) | Implemented | |
| Watch-tag alerts | Implemented | |

### Vision / Surveillance (Sprint L)
| Feature | Status | Notes |
|---|---|---|
| Local webcam feed | Implemented | CameraFeedManager |
| RTSP stream feed | Implemented | RTSPStreamManager |
| Human rectangle detection | Implemented | VNDetectHumanRectanglesRequest |
| Face rectangle detection | Implemented | VNDetectFaceRectanglesRequest |
| Object tracking (IoU + smoothing) | Implemented | ObjectTracker |
| Threat classification (heuristic) | Implemented | linger/velocity/concealment/surveillance rules |
| Threat classification (CoreML/YOLOv8) | Optional/Not bundled | loadCoreMLModel() exists, no model shipped |
| Motion zone engine | Implemented | MotionZoneDescriptor, callback to ProactivityEngine |
| Scene memory store | Implemented | SceneMemoryStore |
| Threat escalation → proactivity signal | Wired (callback set nil at init) | onThreatEscalated never assigned in JarvisController |
| POI HUD overlay | Implemented | |
| Multi-camera (camera + RTSP) | Implemented | feedTargets dictionary per UUID |

### Spatial Gestures
| Feature | Status | Notes |
|---|---|---|
| Hand pose detection | Implemented | VNDetectHumanHandPoseRequest |
| Dominant hand lock | Implemented | wrist continuity tracking |
| Pinch → drag overlay | Implemented | |
| Pinch → open HUD radial | Implemented | |
| Two-hand spread → resize | Implemented | |
| Face exclusion zone | Implemented | prevents face hits registering as gestures |
| Accidental motion suppression | Implemented | AccidentalMotionDetector |
| Adaptive intent scoring | Implemented | AdaptiveIntentScoring |
| Gesture calibration | Implemented | GestureCalibrationStore persisted |
| User-editable gesture→action mappings | Implemented | GestureCommandRegistry persisted JSON |

### Memory & Context
| Feature | Status | Notes |
|---|---|---|
| SQLite memory store (GRDB) | Implemented | |
| FTS search | Implemented | |
| NLEmbedding semantic search | Implemented | |
| Hybrid search | Implemented | dedup by 60-char text prefix |
| Memory injection into LLM | Implemented | top-3 relevant memories in tryLLMFallback |
| Conversation summariser | Implemented | LLM compresses last 20 turns |
| ConversationRouter route-specific answers (Sprint K) | Implemented | JarvisAnswerComposer |
| ActiveContextRegistry | Implemented | records responses per project/topic |

### Ambient Context (Sprint F/G)
| Feature | Status | Notes |
|---|---|---|
| Active app monitoring | Implemented | NSWorkspace notifications |
| Window title tracking | Implemented | CGWindowListCopyWindowInfo |
| Screen sampling / OCR | Implemented | 30s normal, 8s watch mode |
| Privacy filter (passwords, incognito) | Implemented | PrivacyFilter.swift |
| Watch mode (boost sampling rate) | Implemented | activateWatchMode(duration:targetApp:) |
| App context adapters (Xcode/Cursor/Terminal/Safari) | Implemented | |
| Task thread tracking | Implemented | TaskThreadEngine |
| Ambient context overlay | Implemented | |

### Runtime Infrastructure (Sprint G/H)
| Feature | Status | Notes |
|---|---|---|
| SystemBus pub/sub | Implemented | 9 |
| EventStore ring buffer | Exists, not started | start() never called |
| RuntimeCoordinator health polling | Implemented | 30s interval |
| RuntimeCoordinator subsystem start | NOT IMPLEMENTED | register() only stores, never starts |
| ExecutionTrace per-pipeline | Implemented | correlationIDs wired in JarvisController |
| RuntimeDependencyGraph | Implemented | topological order, hard/soft deps |
| ConversationRuntime as real class | Implemented | Sprint H |
| RuntimeDiagnostics overlay | Implemented | EventStore section always empty |

### Security
| Feature | Status | Notes |
|---|---|---|
| Keychain storage (5 integration tokens) | Implemented | |
| Keychain migration from plaintext | Implemented | |
| Plaintext fallback for compat | Implemented (intentional) | |
| preferences.json 0o600 permissions | Implemented | |
| URL scheme allowlist | Implemented | openURL guard |
| Prompt injection structural markers | Partially | [MEMORY CONTEXT] present, no structural delimiters in Obsidian RAG |

### Integrations — Misc
| Feature | Status | Notes |
|---|---|---|
| Clipboard read/write | Implemented | NSPasteboard |
| Wi-Fi toggle | Implemented | networksetup CLI |
| Bluetooth toggle | Implemented | blueutil (requires brew install) or System Settings fallback |
| Screen awareness | Implemented | |
| Android bridge (WebSocket) | Implemented | correlated request/response, 15s timeout |
| Apple Mail integration | NOT IMPLEMENTED | mentioned in TODO |
| Apple Notes integration | NOT IMPLEMENTED | mentioned in TODO |
| Window management (AXUIElement) | NOT IMPLEMENTED | mentioned in TODO |

---

## 4. Orchestration Analysis

### Primary pipeline — fully traced

```
SpeechRecognizer (STT partial/final)
  → handleTranscript()
    → ConversationRuntime.cancelTimeout()
    → SystemBus.publish(ListeningStartedEvent)
    → FollowUpResolver.resolve() [if activePendingContext != nil]
    → ConversationRouter.classify() [if route != .command]
      → JarvisAnswerComposer [if knowledge/project/general]
    → CommandPhraseMatcher.match() [if command route]
    → IntentRouter.route(parsed:) [if phrase match fails]
    → IntentRouter.route(_:) [substring fallback]
    → execute(intent) [if resolved]
    → tryLLMFallback() [if .unknown]
```

This path is real and complete. Every handoff exists in JarvisController.swift.

### Bootstrap sequence (lines 507–1345 in JarvisController)

The bootstrap is sequential and synchronous on MainActor. 14 service groups initialised in order: permissions, camera, WebSocket, wake word, screen, HA, news, Todoist, calendar, weather, GitHub, Shopify, Obsidian, identity, timers, semantic memory, conversation summariser, ambient context, RuntimeCoordinator, spatial.

**Critical gap — RuntimeCoordinator.register() never calls start():**

```swift
// RuntimeCoordinator.swift — register():
func register(_ subsystem: any RuntimeSubsystem) {
    subsystems[subsystem.id] = subsystem
    // ← no start() call here
}

// JarvisController bootstrap calls:
coordinator.register(SystemRuntime())
coordinator.register(MemoryRuntime())
// etc.
coordinator.markReady()  // only publishes RuntimeReadyEvent
```

`markReady()` starts the health polling loop but does NOT start subsystems. `SystemRuntime.start()` (which calls `EventStore.shared.start()`) is never invoked. This means:

- **EventStore never runs.** Its 1000-event ring buffer is permanently empty.
- **RuntimeDiagnosticsOverlay EventStore throughput chart shows nothing.**
- **All RuntimeRegistry shells are no-ops** — their start() implementations are never called.
- `RuntimeCoordinator.healthCheck()` polls subsystems and sees `.stopped` state (since they were never started) but this does not trigger recovery — recovery only triggers on `.failed` state.

The health monitor loop in RuntimeCoordinator calls `subsystem.healthCheck()` and then examines `subsystem.state`. Since none were started, all remain in `.stopped`. The recovery path only fires on `.failed`. So the coordinator runs indefinitely polling stopped subsystems without error and without starting them.

### ProactivityEngine orchestration — fully functional

decide() is 80+ lines of real logic. The path from signal ingress to output is:
`ingest() → decide() → speakNow / showOverlay / showQuietly / logOnly`

All filtering layers are real: enabled check, isPaused (SystemBus-driven), per-source toggles, mute map, priority threshold, user-suppressed set, persistent dedup (keyed by signalKey), in-memory cooldowns map, daily cap counter, quiet hours time check, jarvis_busy check.

Auto-pause on follow-up is wired: `subscribeSystemBus()` subscribes `ConversationAwaitingResponseEvent` → `isPaused = true`, `ConversationFollowUpResolvedEvent` → `isPaused = false`. Both paths traced through SystemBus.

### LLM routing — functional with one silent gap

`tryLLMFallback()` builds context in order:
1. Personality system prompt (PersonalityContextBuilder)
2. Last 4 chat turns from conversation history
3. Pending context if any
4. Top-3 memories from hybridSearch (if memory enabled)
5. Obsidian vault RAG block (if obsidianLLMContextEnabled)
6. Vision/screen context (ContextEngine.currentContext())

Then calls `LLMRouter.complete()` → iterates [miniMax, gemini, lmStudio] with circuit breaker.

**Silent gap:** `LLMIntentBridge.parse()` is called on the LLM response to extract an Intent. If parsing returns `.unknown`, the code silently exits without speaking. There is no error response to the user, no "I didn't understand that." The silence is absolute.

---

## 5. Conversational Intelligence Analysis

### Session management — solid

ConversationRuntime owns the 10-minute armed window. arm() launches a Task.sleep. If the user speaks within the window, `cancelTimeout()` resets it. `endSession(permanent: false)` restarts STT after 150ms when silence timeout fires. The session can only be permanently ended by: "stop listening", app close, mic failure, or 10-minute inactivity. All other events (TTS finish, overlay open, unknown command) correctly leave the session running.

### Follow-up resolution — capable

FollowUpResolver handles 4 types:
- `.yesNo` — word-list matching (yes/no, sure/nope, etc.)
- `.clarification` — exact→contains chain with re-ask
- `.freeform` — captures transcript directly
- `.choice` — fuzzy match against provided options, re-asks if below threshold

Contextual pronoun resolution ("open that", "close that", "summarise that", "dismiss that") is a separate path that inspects `overlayManager.topOverlay` before routing.

**Gap:** No per-context timeout differentiation. All contexts use a 20-second timeout regardless of type. A freeform question (e.g., "what would you like me to note?") gives the same 20 seconds as a yes/no.

### ConversationRouter (Sprint K) — conservative by design

5 routes: command, memoryUpdate, knowledgeQuery, projectReflection, generalChat.

The classifier is O(n) string matching with static signal tables. Confidence is computed as the ratio of matched signals to total signals checked (capped at 1.0). The `shouldShortCircuit` flag fires when confidence ≥ 0.70 AND route is not command/ignore/clarification.

The design is deliberately conservative: when in doubt, it falls through to command routing. This means edge cases default to the right behaviour (execute intent) rather than answering with LLM when a command was intended.

**Gap:** The confidence model is additive over signal count — a transcript with 3 "general chat" words beats a transcript with 1 very strong command signal. No weighting by signal specificity.

### LLM context injection — thorough

tryLLMFallback injects up to 5 context layers. The ordering (personality → history → pending → memory → vault → vision) is sensible: high-confidence personal context first, potentially-stale external context last.

**Gap:** Obsidian vault RAG injects raw note body text without structural delimiters. Memory context uses `[MEMORY CONTEXT]` markers. Inconsistency in prompt engineering could confuse smaller models.

---

## 6. Contextual Intelligence Analysis

### What it actually knows at runtime

When the assistant responds to any voice command:
- Active application name and bundle ID (updated on NSWorkspace didActivate)
- Current window title (5s poll via CGWindowListCopyWindowInfo)
- Optional screen summary (30s OCR via Vision framework)
- Up to 3 relevant Obsidian vault notes (hybrid search against query)
- Up to 3 relevant memories (hybridSearch against query)
- Last 4 conversation turns
- Current time, pending context

### What it does NOT know

- File contents (no file system monitoring beyond Obsidian vault)
- Multi-monitor state (no display arrangement awareness)
- Browser tab list (screen OCR only captures visible content)
- Current terminal command output (no pty integration)
- Clipboard history (single current value only)
- Notification center contents

### AppContextAdapters — genuinely useful

CursorAdapter, XcodeAdapter, TerminalAdapter, SafariAdapter each extract structured context from window titles and OCR lines: active file path, repo name, branch, build status, active URL. These feed `TaskThreadEngine` which builds `TaskThread` models — sequences of related app contexts.

**Gap:** AppContext adapters are only called during screen sampling (30s intervals). A user who opens Xcode and immediately asks "what's the build error?" may get stale or empty context if the 30s cycle hasn't fired yet.

### Watch mode — effective when used

activateWatchMode(duration:targetApp:) boosts sampling to 8s. Activated by "watch this" intent. Auto-expires via Task.sleep. This is the right design for the use case.

---

## 7. Proactive Intelligence Analysis

### Eight proactivity providers

| Provider | Real polling? | Signal quality |
|---|---|---|
| CalendarProactivityProvider | Yes, 60s | High — EventKit, 10min + 1min alerts |
| TodoistProactivityProvider | Yes, 5min | High — morning overdue announcement |
| GitHubProactivityProvider | Yes, 10min | High — review requests, mentions, assignments |
| WeatherProactivityProvider | Yes, 15min | High — morning briefing, severe, rain |
| HomeAssistantProactivityProvider | Yes, WebSocket event-driven | High — state_changed stream |
| ShopifyProactivityProvider | Yes, 5min | Medium — new order + low stock |
| ObsidianProactivityProvider | Yes, 5min | Medium — watch tags, recent modifications |
| ThreatClassifier (via VisionModule) | Yes, per-frame | Low-medium — heuristic rules only |

All 8 are started from JarvisController bootstrap. All emit signals through ProactivityEngine.ingest(). The filtering stack (quiet hours 23:00–07:00, daily max 10, per-source cooldowns 60–300s, dedup, per-source toggles) applies to all.

**Gap:** Smoke/CO bypass quiet hours is implemented but only for HA smoke/CO events — the ThreatClassifier's "high" threat signals still respect quiet hours. A real break-in at 2am would be silenced.

**Gap:** ProactivityEngine's persistent dedup key is based on signal content hash. If a door is opened, closed, and opened again within the cooldown window, the second opening is silenced. This is intentional but could suppress important repeat events (e.g., door opened twice in quick succession by different people).

---

## 8. Architecture Risk Analysis

### Risk 1 — JarvisController god class (CRITICAL)

JarvisController.swift is 8,398 lines. It owns ~60+ service references, the entire bootstrap sequence, the full execute() switch (~200+ Intent cases), and all callback closures for every subsystem.

This creates several practical problems:
- Any new Intent requires editing the same 8 400-line file
- All services depend on JarvisController for their wiring (circular initialization pattern)
- Testing individual subsystems in isolation is impossible without the full JarvisController initialization chain
- The file is already at the practical limit for AI assistance tools (requires chunked reading)

The RuntimeSubsystem/RuntimeCoordinator architecture was introduced to solve exactly this problem, but was never connected (see Risk 2). Without that connection, the god class pattern is locked in.

### Risk 2 — EventStore / RuntimeRegistry dead code (HIGH)

EventStore.shared.start() is never called. The 1000-event ring buffer never fills. RuntimeDiagnosticsOverlay shows an empty throughput chart. This is not theoretical — it is verifiable by reading RuntimeCoordinator.markReady() and confirming no start() call exists anywhere for registered subsystems.

All 8 RuntimeRegistry shells have real start() implementations (they delegate to singleton services), but they are never executed. The execution contract between RuntimeCoordinator and its registered subsystems is broken.

**Fix:** RuntimeCoordinator.markReady() should call `start()` on all registered subsystems in topological order (RuntimeDependencyGraph.topologicalOrder() already exists for this purpose).

### Risk 3 — GitHubCodeReviewEngine LLM disabled (MEDIUM)

JarvisController initializes GitHubModule as:
```swift
GitHubModule(token: githubToken)
```
GitHubModule's initializer signature accepts an optional `llmRouter: GHLLMCapable?` parameter that defaults to nil. JarvisController never passes its llmRouter. GitHubCodeReviewEngine falls back to pure heuristics (size/complexity/review count). The LLM-powered code review advertised in Sprint J notes does not run.

**Fix:** One line: `GitHubModule(token: githubToken, llmRouter: llmRouter)`

### Risk 4 — onThreatEscalated never assigned (MEDIUM)

VisionModule declares:
```swift
var onThreatEscalated: ((ThreatLevel, String) -> Void)? = nil
```

JarvisController wires `onMotionZoneTriggered` but never assigns `onThreatEscalated`. Threat escalation events from the vision system are silently dropped. The surveillance system detects threats but cannot alert the user.

**Fix:** In JarvisController bootstrap, add:
```swift
visionModule.onThreatEscalated = { [weak self] level, description in
    // emit ProactivitySignal or speak alert
}
```

### Risk 5 — LLM silent failure on parse error (MEDIUM)

When `tryLLMFallback()` calls `LLMIntentBridge.parse()` and receives `.unknown`, the function returns without speaking. The user hears nothing. From the user's perspective, Jarvis simply did not respond.

This is the worst possible failure mode for a voice assistant: the user assumes the system did not hear them and repeats the command, potentially triggering a double-execution or infinite retry loop.

**Fix:** Add a final fallback response when LLM parse returns .unknown:
```swift
if result == .unknown {
    speak(renderer.render(ResponseKey.fallbackUnknown, [:]))
}
```

### Risk 6 — IntentRouter regex compiled per-call (LOW-MEDIUM)

IntentRouter.route(_:) uses NSRegularExpression for timer parsing (e.g., time extraction from "set a timer for 5 minutes"). These are initialized inside the function body, compiled on every call. With ~100ms STT latency and typical conversational cadence, the overhead is probably not perceptible, but it is wasteful.

**Fix:** Make them `static let` class properties (noted as TODO in CLAUDE.md, not yet done).

### Risk 7 — shopifyStatus recursive execute() call (LOW)

A `shopifyStatus` intent handler contains a recursive call to `execute()`. If the recursion condition is met, this is an unbounded recursive call. Line ~3022 of JarvisController.swift.

### Risk 8 — Preferences.json still contains token fields (LOW)

All 5 integration tokens are read from Keychain via computed vars. The plaintext fields still exist in the Preferences struct with empty defaults. The migration correctly clears them. However, the fields remain available as fallbacks, meaning any future code that directly reads `prefs.current.shopifyAccessToken` (bypassing the computed var) will get an empty string rather than a Keychain error, silently failing.

---

## 9. Security + Privacy Analysis

### Tokens and secrets

All 5 integration tokens (HA, Todoist, GitHub, Shopify, Spotify) are stored in macOS Keychain via `Security.SecItemAdd`. The migration runs at app launch: writes to Keychain, then clears plaintext. The computed vars in PreferencesStore read Keychain first with plaintext fallback.

`preferences.json` has 0o600 permissions (user read/write only). The containing directory has 0o700 (user only). These are set at write time.

**Gap:** MiniMax API key and Gemini API key are stored in Keychain (`miniMaxAPIKey`, `geminiAPIKey`) but there is no migration path from any potential legacy storage. First-time setup requires manual Keychain entry or the Settings UI.

### Privacy filter

PrivacyFilter.isBlocked() checks bundleID against a hardcoded list (1Password, Bitwarden, Keychain Access, KeePassXC) and name substrings (incognito windows, private browsing). Blocked apps emit `ContextRedactedEvent` and no screenshot or OCR is performed.

**Gap:** No system prompt injection guard. Obsidian vault notes are injected raw into the LLM context. A malicious Obsidian note containing "Ignore all previous instructions" would be injected verbatim. There are structural markers (`[MEMORY CONTEXT]`) for memory but none for Obsidian RAG.

**Gap:** Screen OCR output is injected into LLM context gated only by `llmSendsScreenContext` preference (default unknown from audit). If this is true by default, screen content (potentially including passwords visible on screen, private documents, etc.) is sent to external LLM providers (MiniMax, Gemini).

### openURL allowlist

`openURL` in JarvisController has an allowlist check before opening URLs from LLM responses. This was added during the audit period and is present. The allowlist covers common schemes (https, http, mailto).

### Microphone access

AVAudioSession / AVCaptureDevice access uses standard macOS permission flow. No evidence of audio stream exfiltration — all processing is local (Whisper GGUF) or via Apple Speech.

---

## 10. UX Coherence Analysis

### Voice response quality — high

ResponseRenderer with variable substitution, multiple phrase variants per ResponseKey, and personality overlays produces natural-sounding spoken responses. The 300+ ResponseKey entries cover most user-facing intents.

The silent LLM failure (Risk 5) is the single biggest UX defect: a non-response from a voice assistant is experienced as a crash or a hard-of-hearing moment.

### Overlay system — coherent but uneven

25 OverlayKind cases are declared. Of these, approximately 18 have real SwiftUI view implementations. The `isImplemented` flag gates access to prevent opening unimplemented overlays. The resize, pin, and close behaviours are uniform.

The overlay stack model (array with push/pop) works well for the primary use case (one overlay at a time). The pinned overlay concept (skipping pinned in closeTopOverlay) is correct.

**Gap:** No keyboard navigation within overlays. All interaction is voice + gesture + click.

### Settings UI — comprehensive

SettingsView covers 8 tabs: General, Voice, AI, Home, Integrations, Personality, Unmatched Commands, Obsidian. API token fields, all preference toggles, and diagnostic controls are present.

### Gesture interaction — sophisticated but invisible

The gesture system is technically capable (pinch/drag/spread/hold/HUD radial menu). But there is no visual affordance for what gestures are available. A new user has no way to discover the gesture vocabulary without reading documentation.

The `GestureCommandRegistry` (user-editable gesture→action mappings) is persisted and surfaced in settings, which partially addresses this.

### Proactivity UX — well-filtered but non-dismissible in HUD

ProactivityEngine's notification tray (`pendingSignals`) is available via overlay. Individual signals can be dismissed via `engine.dismiss(signalId)`. But when a proactive alert fires as TTS during a task (e.g., "Timer expired" while the user is on a call), there is no mechanism to mute that source temporarily from voice alone.

`engine.mute(.timerExpiry, for: 3600)` exists in the API but is not exposed as a voice command.

---

## 11. Hidden Gem Systems

These are genuinely impressive implementations that are not obvious from the feature list:

### 1. ExecutionTrace with correlation IDs

Every pipeline invocation (wake → STT → intent → TTS) is traced with a correlation ID. Steps are recorded with timestamps and runtimeID. The 50-trace ring buffer means the last 50 full interactions are inspectable. This is production-quality observability for a personal assistant — most commercial voice assistants do not expose this.

### 2. RuntimeDependencyGraph

A topological sort of 9 subsystems with hard and soft dependencies is implemented and correct. `topologicalOrder()` uses DFS with cycle detection. `isHardBlocked(_:by:)` and `restartPrerequisites(for:)` provide proper dependency-aware restart logic. The graph is correct and would work — it just isn't wired to RuntimeCoordinator's startup sequence yet.

### 3. TaskThreadEngine

Builds TaskThread models from sequences of app context changes. A "thread" is a coherent work session: opens Xcode → opens terminal → runs build → sees error. This is not stored anywhere permanently, but it is the right abstraction for a context-aware assistant that can say "you were working on the auth module, want me to summarise the error you saw?"

### 4. AdaptiveIntentScoring in gesture system

The gesture system records hit accuracy per-gesture type and adjusts confidence thresholds. Pinch gestures that frequently trigger accidental activations get a higher suppression weight. This is adaptive calibration without ML — pure statistical feedback.

### 5. LivingDocumentationEngine with 14 contributors

14 subsystems register as documentation contributors at bootstrap. Help queries generate real-time documentation by calling all contributors' sections. The documentation is always current because it queries live system state (active feeds, registered commands, current settings). This is a genuinely clever design for a system that evolves rapidly.

### 6. ConversationRouter conservative default

The ConversationRouter defaults to `.command` when uncertain. This means LLM is only invoked when the classifier has reasonable confidence the query is not a command. The threshold (0.70) was clearly chosen to prevent false positives (accidentally routing "turn off the lights" to the LLM and getting a response instead of an action). The design shows careful thinking about failure modes.

---

## 12. Most Important Missing Capabilities

Ranked by impact on the core assistant use case:

### P0 — Fix EventStore never-starting

The event infrastructure for the entire runtime is broken. RuntimeDiagnosticsOverlay, EventStore query API, and all RuntimeRegistry subsystem start() implementations are dead code. One fix: add subsystem.start() calls in RuntimeCoordinator.markReady().

### P0 — Fix LLM silent failure

When LLM parse returns .unknown, the user hears silence. This is a worse outcome than "I didn't understand that." One fix: speak a fallback response.

### P0 — Wire onThreatEscalated in VisionModule

The surveillance threat escalation path is fully implemented except for the final callback assignment. A three-line fix would make the vision system emit ProactivitySignals on threat detection.

### P1 — Wire GitHubCodeReviewEngine llmRouter

One parameter. Unlocks LLM-powered code review that was already built in Sprint J.

### P1 — Email integration

The most common proactivity source for professional users is email. Every other productivity integration is present (calendar, tasks, GitHub, Shopify, Obsidian). Apple Mail AppleScript or IMAP polling would complete the coverage.

### P1 — Prompt injection guard for Obsidian RAG

Obsidian vault notes are injected raw into LLM prompts. Structural delimiters and sanitisation of the `---` YAML frontmatter separator would reduce injection risk.

### P2 — Voice-accessible source muting

"Mute timer alerts for an hour" / "stop GitHub notifications for today" would improve proactivity UX significantly. ProactivityEngine.mute() already exists — just needs IntentRouter wiring.

### P2 — Visual gesture affordances

The gesture vocabulary (pinch, spread, hold, HUD radial) is invisible to new users. A one-time onboarding overlay or persistent hint system would improve discoverability.

### P2 — Screen context timing

AppContext adapters only fire on 30s screen sampling intervals. A "describe what's on screen" intent right after a screen change gets stale data. Watch mode partially solves this (8s) but requires manual activation.

### P3 — Apple Notes integration

Notes AppleScript is a single `tell application "Notes" to make new note` call. Low effort, high value for note-taking workflows.

### P3 — Window management (AXUIElement)

Position/resize/tile windows by voice. AXUIElement is complex but well-documented. Useful for power users who already use voice for everything else.

---

## 13. Evolution Roadmap

### Phase 1 — Close open circuits (1–2 days)
Fix the 4 P0/P1 wiring gaps: EventStore start(), LLM silent failure, onThreatEscalated, GitHubCodeReviewEngine llmRouter. These are all 1–5 line changes that unlock already-built functionality.

### Phase 2 — Prompt safety hardening (2–3 days)
Add structural delimiters to all LLM context injection points. Move LLM context behind per-context preference flags. Add response validation before speaking LLM output. Rate-limit LLM calls per session.

### Phase 3 — JarvisController decomposition (1–2 weeks)
Extract execute() into an IntentExecutor class. Extract the bootstrap sequence into a BootstrapOrchestrator. Extract each integration's execute cases into handler objects that implement a common protocol. JarvisController becomes a thin coordinator (~500 lines) that owns service lifecycle and wires handlers.

### Phase 4 — Email integration (3–5 days)
Apple Mail AppleScript + VIP/keyword proactivity provider. Integrates naturally with existing ProactivityEngine and FollowUpResolver ("reply to Chris" follow-up flow).

### Phase 5 — Real-time context injection (3 days)
Replace 30s screen sampling with event-driven sampling on NSWorkspace didActivate + window focus change. Context is always fresh when the user speaks. Eliminates the stale-context problem for AppContextAdapters.

### Phase 6 — Multi-modal response generation (1 week)
When vision context + LLM fallback both fire, allow LLM to generate responses that reference what it "sees" in the camera feed. Currently these are separate paths. Unified context = richer, more grounded responses.

### Phase 7 — Persistent task threads (3 days)
Persist TaskThread models to the SQLite memory store. Allows Jarvis to say "last time you were working on this, you got to X" across sessions. TaskThreadEngine already builds the right abstraction.

### Phase 8 — Proactivity ML layer (2–3 weeks)
Replace heuristic quiet-hours and cooldown rules with a simple learned model: given signal type, time of day, current activity, and user's historical accept/dismiss rate — predict whether to surface. Requires logging accept/dismiss actions (not currently done).

### Phase 9 — Voice accessibility mode (1 week)
Add an accessibility mode where all gesture interactions have voice equivalents, all overlays have spoken navigation commands, and the gesture affordance problem is solved via audio cues. Makes the full gesture vocabulary discoverable without a tutorial.

### Phase 10 — Full runtime extraction (2–3 weeks)
Complete the vision for RuntimeCoordinator: topological startup, coordinated shutdown, cross-subsystem dependency awareness for recovery, and a unified health dashboard that is actually populated (EventStore running). The infrastructure is 80% built; the remaining 20% connects it to real execution.

---

## 14. Final Verdict

### What Jarvis genuinely is

A technically sophisticated personal voice assistant with a real implementation beneath the surface. The core pipeline (wake → STT → intent → execute → TTS) is solid and battle-tested. The proactivity system is the most carefully engineered component: 8 live providers, a 7-layer decision stack, and correct SystemBus integration for auto-pause. The memory and RAG systems are real: NLEmbedding cosine search, hybrid FTS+semantic, Obsidian vault injection. The spatial gesture system is the most ambitious and most complete gesture-to-overlay interaction system I have seen in a personal project.

### What it is not

It is not the event-driven runtime it was designed to be in Sprints G and H. EventStore never starts. RuntimeRegistry subsystems never start. The dependency graph and topological sort exist but are not used. The architecture documents describe a system that does not fully run.

It is not an ML-powered surveillance system. ThreatClassifier is pure geometric heuristics. The CoreML hook exists but no model is bundled. This is honest but should not be described as AI-powered threat detection.

It is not a fully coherent product from a user experience standpoint. The gesture vocabulary is invisible, the silent LLM failure is jarring, and the vision threat escalation callback is unwired.

### The gap

The gap between what has been built and what is running is mostly in the integration layer — not in the subsystem implementations themselves. The subsystems are correct. The connections between them have several missing final wires. This is a common pattern in ambitious solo engineering: the hard parts (vision pipeline, gesture state machine, topological dependency graph, correlated execution tracing) are done; the unglamorous wiring tasks are deferred.

### Score

| Dimension | Score |
|---|---|
| Core voice pipeline | 9/10 |
| Integration breadth | 8/10 |
| Architecture design | 7/10 |
| Architecture execution | 5/10 |
| Conversational intelligence | 7/10 |
| Contextual intelligence | 6/10 |
| Proactive intelligence | 8/10 |
| Security | 7/10 |
| UX coherence | 6/10 |
| **Overall platform maturity** | **6.8/10** |

The ceiling is clearly 8.5–9/10 if the wiring gaps are closed. The foundation is genuinely strong. The most important next action is not building new features — it is closing the 4 open circuits that would make already-built systems run.
