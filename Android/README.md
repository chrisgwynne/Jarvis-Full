# Jarvis — Android AI Assistant

A fully on-device, voice-first AI assistant for Android. Jarvis runs as a persistent foreground service, wakes on a custom wake word, and handles natural conversation, device control, smart home automation, proactive suggestions, and a growing suite of tools — all without cloud dependency for core processing.

---

## Features

### Voice & Conversation
- **Wake-word detection** — TFLite model + Google fallback, adaptive threshold based on ambient noise
- **Barge-in** — interrupt Jarvis mid-sentence; classified as urgent/correction/continuation/clarification and handled appropriately
- **Multi-turn context** — conversation history compressed and carried across turns; slot extraction and entity tracking for follow-ups
- **Speaker recognition** — enrol multiple voice profiles; per-speaker trust and command permissions
- **Local TTS** — Piper ONNX on-device TTS with configurable voice; Android TTS as fallback
- **STT** — on-device speech recogniser (Android 12+ `createOnDeviceSpeechRecognizer`); vocabulary biasing for Home Assistant entity names

### Tools (40+)
| Category | Tools |
|----------|-------|
| **Calls & Messaging** | Make/answer/end calls, send SMS, WhatsApp messages, reply to notifications, quick reply, read recent messages |
| **Device** | Volume, brightness, DND, flashlight, screen rotation, clipboard, find-my-phone, open/close apps, scroll, tap screen, take screenshot, OCR scan, camera capture |
| **Calendar & Reminders** | Create/read calendar events, set alarms and timers, location-based reminders, Todoist integration |
| **Navigation** | Google Maps directions with turn-by-turn spoken guidance, saved places, nearest place lookup |
| **Smart Home** | Home Assistant control (lights, switches, climate, media), WebSocket live events |
| **Memory** | Persistent personal facts, recall by topic, knowledge graph with contradiction detection |
| **Web & Media** | Web search, weather, music search, media playback control |
| **Productivity** | Shopping list, email (Gmail), daily briefing, voice shortcuts, routines, action graphs |
| **Vision** | Screen reader, visual follow-up ("what's on screen?"), camera vision analysis, wearable context (Meta glasses) |

### Proactive Engine
Five interrupt levels from silent awareness (L0) through active intervention (L4). Gates:
- Global gap timer (60 s default)
- Quiet hours (22:00–07:00)
- Presence gate — defers soft suggestions when driving, winding down, or mid-conversation
- Per-key adaptive cooldown — ignoring a suggestion stretches its cooldown, accepting it tightens it

Trigger sources include: upcoming meetings, low battery, missed calls, unread notifications, HA motion/door/lock events, calendar travel time, location transitions, behavioural learning patterns, and Todoist reminders.

### Mac Bridge
Bidirectional bridge over WebSocket connecting Jarvis on Android to a companion Mac agent. Role arbitration (`FULL_ASSISTANT` vs `BRIDGE_ONLY`) prevents double-processing. QR-code pairing, capability negotiation, live connection state in diagnostics.

### Overlay Cards
Floating Compose UI rendered via `SYSTEM_ALERT_WINDOW`. Cards appear for action confirmations, smart replies, HA alerts, navigation prompts, and diagnostics. Swipe-to-dismiss, per-type cooldowns, entity-level dedup. Gated through `OverlayPolicy` (master toggle, bridge mode, HA toggle, global/per-entity cooldowns).

### Reliability Layer
- **`ListenerDiagnostics`** — live counters for wake detector, speech recogniser, overlay view, HA subscription, Mac bridge, notification buffer; last audio focus event and listen-stop reason
- **Listener watchdog** — detects unexpected wake-detector absence in `IdleWake` state; restarts once per session and logs `[listener_watchdog_restart]`
- **`HealthMonitor`** — tracks service and overlay running state
- **Auto issue reporter** — files scrubbed GitHub issues on crashes/HIGH-severity exceptions, rate-limited and fingerprint-deduplicated
- **Architecture invariants** — `./gradlew checkArchitectureInvariants` enforces routing rules at build time

---

## Requirements

| | |
|-|--|
| **Android** | 10+ (API 29+) |
| **Compile SDK** | 35 (Android 15) |
| **Target SDK** | 34 |
| **Build tools** | AGP 9+, Kotlin 2.2, KSP |

---

## Building

### 1. Clone

```bash
git clone https://github.com/chrisgwynne/Jarvis.git
cd Jarvis
```

### 2. `local.properties`

Create `local.properties` at the repo root (already gitignored):

```properties
# Android SDK — required
sdk.dir=/path/to/Android/sdk

# LLM provider keys — add whichever you use
anthropic_api_key=sk-ant-...
openai_api_key=sk-...
openrouter_api_key=sk-or-...
gemini_api_key=...

# GitHub auto-reporting (optional — dev/owner mode only)
github_token=ghp_...
github_owner=chrisgwynne
github_repo=Jarvis

# Meta Wearables DAT SDK (optional)
# meta.wearables.applicationId=
# meta.wearables.clientToken=AR|...|...
# github_token=ghp_...   ← also controls whether src/mwdat/java is compiled
```

### 3. Build

```bash
./gradlew assembleDebug
```

Install:

```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

### 4. Run tests (unit only — no instrumented required)

```bash
./gradlew testDebugUnitTest
```

Architecture invariants:

```bash
./gradlew checkArchitectureInvariants
```

---

## Permissions

All permissions map to a concrete feature. Full table in [`docs/PERMISSIONS.md`](docs/PERMISSIONS.md).

Key runtime grants requested on first launch:

| Permission | Feature |
|------------|---------|
| `RECORD_AUDIO` | Wake word, STT, barge-in |
| `CAMERA` | Vision tools (lazy-requested) |
| `CALL_PHONE` / `ANSWER_PHONE_CALLS` | Call tools |
| `READ_CONTACTS` | Contact lookup + alias resolution |
| `SEND_SMS` | SMS tool |
| `ACCESS_FINE_LOCATION` | Location context + geofence reminders |
| `POST_NOTIFICATIONS` | Foreground service + reminder alerts |

Special-access grants (directed to system Settings):

- **Notification access** — `JarvisNotificationListener` for reading + replying to notifications
- **Accessibility service** — opt-in screen context reader (`JarvisAccessibilityService`)
- **Display over other apps** (`SYSTEM_ALERT_WINDOW`) — overlay cards
- **Battery optimisation exemption** — keeps the foreground service alive
- **Call screening** — `JarvisCallScreeningService`

---

## Configuration

All settings are persisted via `SettingsStore` (SharedPreferences). There is no remote config — every setting is in-app.

### LLM Provider

Settings → AI Model. Supported providers:

| Provider | Notes |
|----------|-------|
| **Anthropic (Claude)** | Default; streaming, tool use |
| **OpenAI** | GPT-4o and variants |
| **Google Gemini** | Gemini Flash / Pro |
| **OpenRouter** | Route to any model via openrouter.ai |
| **Ollama** | Self-hosted local models |
| **OpenClaw** | Self-hosted OpenAI-compatible endpoint |
| **Hermes Agent** | Self-hosted job-queue agent |
| **MiniMax / Kimi** | Additional cloud providers |

`LlmRouter` caches the active provider instance; switching provider in settings replaces it on the next turn.

### Home Assistant

Settings → Home Assistant. Provide your HA base URL and long-lived access token. The WebSocket client subscribes to `state_changed` events for real-time overlays and proactive alerts. Alert-worthy entities (motion, door, lock, alarm, smoke, leak, window, garage) surface as `HOME_ASSISTANT_ALERT` overlay cards.

### Proactivity

Settings → Proactivity. Individual toggles per event type (meetings, battery, missed calls, notifications, HA alerts, location transitions, behavioural learning). Global on/off, quiet hours, and per-type cooldowns.

### Overlay Cards

Settings → Appearance → Overlays. Master enable/disable. Individual HA alert toggle. Per-entity cooldowns (120 s) and global HA cooldown (15 s) are hardcoded in `OverlayPolicy`.

### Mac Bridge

Settings → Mac Bridge. Paste the WebSocket URL from the Mac companion, or scan the QR code. Role arbitration is automatic.

---

## Architecture

Full detail in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### Process model

```
BootReceiver / MainActivity
        │
        ▼
JarvisService (foreground)
        │
        └── JarvisRuntime (Dispatchers.IO)
                 ├── WakeWordDetector
                 ├── SpeechCapture  →  FollowUpCoordinator  →  LlmRouter
                 ├── TtsEngine
                 ├── ProactiveEngine
                 ├── EventBus (battery, network, telephony, HA, …)
                 └── MacBridgeClient / RoleArbitrator
```

### Voice pipeline

```
WakeWordDetector
   │ onDetected
   ▼
JarvisStateMachine: IdleWake → WakeDetected → Listening
   │ SpeechCapture.listen()
   ▼
JarvisStateMachine: Processing
   │ IntentClassifier → ToolRegistry (instant path)
   │   or LlmRouter.streamWithMessages (free-form)
   ▼
TtsEngine.speak()  ← interruptible by BargeInDetector
   │
   ▼
IdleWake (loop)
```

### Latency target

< 400 ms end-of-speech → first audible TTS token. Full budget breakdown in [`docs/LATENCY_BUDGET.md`](docs/LATENCY_BUDGET.md).

```
STT finalisation       30 ms
Intent / tool match    20 ms
Memory + context       50 ms
LLM → first token     220 ms
TTS first frame        80 ms
```

### Key packages

| Package | Responsibility |
|---------|---------------|
| `runtime.*` | `JarvisRuntime` orchestrator, `ToolDispatcher`, `ResponseFormatter`, `VoicePipeline` |
| `audio.*` | Wake-word detectors (TFLite + Google), `SpeechCapture`, `TtsEngine`, `BargeInDetector`, BT SCO, audio focus |
| `llm.*` | `LlmRouter`, `NetworkClient`, per-provider streaming implementations |
| `memory.*` | Room DB, `MemoryWriter`, `MemoryRetriever`, `ProfileMemoryService`, compression |
| `knowledge.*` | Wiki + facts compiler, query engine, contradiction detection, retention policy |
| `core.decisions.*` | `TriggerEngine`, `DecisionBrain`, situation registry, action ledger |
| `core.events.*` | `EventBus`, typed adapters (battery, network, telephony, BT, foreground app, HA) |
| `proactive.*` | `ProactiveEngine`, `DecisionEngine`, `EventScorer`, cooldown store, follow-up engine |
| `overlay.*` | `JarvisOverlayService`, `OverlayCardManager`, `OverlayPolicy`, `OverlayEventBridge`, Compose renderer |
| `reliability.*` | `ListenerDiagnostics`, `HealthMonitor`, `ServiceWatchdog`, `PermissionStateObserver` |
| `remote.macbridge.*` | `MacBridgeClient`, `RoleArbitrator`, `AndroidEventBroadcaster` |
| `remote.openclaw.*` | Self-hosted OpenAI-compatible client |
| `tools.*` | 40+ device / web / smart-home tools registered into `ToolRegistry` |
| `accessibility.*` | Screen-context inspector (`ScreenInspector`) + actuator (opt-in) |
| `session.*` | `SessionStateEngine`, `SessionIntelligenceCoordinator`, task continuation |
| `followup.*` | `FollowUpCoordinator`, `EntityTracker`, `SlotExtractor`, clarification manager |
| `proactive.scheduled.*` | Calendar, local, and Todoist reminder sources → `ScheduledReminderEngine` |
| `reporting.github.*` | `IssueReporter`, fingerprint dedup, rate limiter, offline queue |
| `ui.*` | Compose surfaces (main screen, settings tree, orb animation, waveform) |

---

## Debugging

### Logcat tags

| Tag | What |
|-----|------|
| `JarvisRuntime` | State transitions, wake events, `[listen_stop] reason=...` |
| `JarvisLatency` | Per-stage pipeline timings, `[BUDGET_BREACH]` warnings |
| `OverlayService` | Window attach/detach |
| `OverlayPolicy` | `overlay_suppressed reason=...` |
| `RoleArbitrator` | Bridge role transitions |
| `MacBridgeClient` | WebSocket connect/disconnect |
| `[listener_watchdog]` | Wake-detector health checks and restarts |
| `[listen_stop]` | Every silence() call with reason |

### Diagnostics overlay

From any screen, trigger `OverlayEventBridge.showDiagnostics()` (or via the debug menu in Settings → Advanced) to surface a live `DIAGNOSTICS` card showing:

```
Role: FULL_ASSISTANT  State: IdleWake
Wake: 1  STT: 0  Overlay: 1
HASubs: 1  Bridge: 0  NotifBuf: 3
StopReason: —
Focus: —
BlockReason: —
Watchdog: 0
```

### Measuring latency

```bash
adb logcat -s JarvisLatency
```

### Architecture invariants

```bash
./gradlew checkArchitectureInvariants
```

Enforces that `LlmRouter`, `ToolRegistry`, and slot-extraction patterns are only accessed through declared routing layers.

---

## Auto issue reporting

When `githubReportingEnabled` is on (owner/dev mode), Jarvis automatically files scrubbed GitHub issues for crashes and HIGH-severity exceptions. Reports are fingerprinted, rate-limited (N occurrences before filing, per-fingerprint cooldown, daily cap), and the stack traces are sanitised before leaving the device. See [`docs/AUTO_REPORTING.md`](docs/AUTO_REPORTING.md).

---

## Project structure

```
app/
├── src/
│   ├── main/
│   │   ├── java/com/jarvis/assistant/   ← all source packages
│   │   ├── assets/voices/               ← Piper ONNX voice models
│   │   └── AndroidManifest.xml
│   ├── mwdat/java/                      ← Meta DAT SDK sources (optional, needs github_token)
│   └── test/java/                       ← unit tests
docs/
├── ARCHITECTURE.md
├── LATENCY_BUDGET.md
├── PERMISSIONS.md
├── AUTO_REPORTING.md
└── architecture/
    └── routing-invariants.md
```

---

## Roadmap highlights

- [ ] Split `JarvisRuntime` god object into focused coordinators
- [ ] Streaming TTS providers (ElevenLabs, OpenAI streaming) for sub-sentence playback start
- [ ] Aggressive conversation compression to stay within context windows on long sessions
- [ ] Baseline profile regeneration after major refactors
- [ ] Measurement Protocol integration to forward Shopify orders to GA4

---

## Licence

Private repository — all rights reserved.
