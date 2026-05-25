# Jarvis Architecture

## Core Principle

**JarvisBrainDaemon is the permanent Jarvis identity.**
Client apps are disposable frontends that connect to it.

---

## Component Roles

### JarvisBrainDaemon (Mac background process)
- **Port**: 8765 (public)
- **Role**: Brain runtime, routing authority, auth authority
- **Owns**: WebSocket server, pairing, device registry, routing, presence, offline queue
- **Survives**: App restarts, network interruptions, client disconnects
- **Does NOT require**: JarvisMac, any specific client app

### JarvisMac (Mac menubar app)
- **Role**: Intelligence engine and UI frontend
- **Connects to**: Daemon at ws://127.0.0.1:8765/v1/mac/ws
- **Owns**: LLM pipeline, TTS, STT, overlays, settings UI, camera
- **Does NOT own**: External WebSocket server, pairing, device auth

### Android App
- **Role**: Mobile frontend with STT/TTS/sensors/tools
- **Connects to**: Daemon at ws://[host]:8765/v2/ws (or /v1/android/ws)
- **Does NOT connect to**: JarvisMac directly

### Windows App
- **Role**: Desktop frontend with Windows automation
- **Connects to**: Daemon at ws://[host]:8765/v2/ws
- **Does NOT connect to**: JarvisMac directly

---

## Message Flow

### Voice command (any device)
```
Device STT → transcript.final → Daemon
                                  ↓ (routes to Mac)
                               Mac app
                                  ↓ (brain pipeline: LLM, tools, TTS)
                               reply.final → Daemon
                                               ↓ (routes to originating device)
                               Device TTS speaks reply
```

### Mac app offline
```
Device STT → transcript.final → Daemon
                                  ↓ Mac offline
                               Offline queue (DaemonOfflineQueue)
                               NACK → originating device
                                  ↓ Mac reconnects
                               Queue drained → Mac processes
```

---

## Auth Model

All client authentication is daemon-owned.

- Pairing: 6-digit code exchange via daemon HTTP API
- Sessions: opaque token stored securely on device, validated by daemon SHA-256 hash
- Mac app: authenticated via shared Keychain gateway token (same machine)
- File: `~/Library/Application Support/JarvisMac/gateway_paired_devices.json`

---

## Mac app when daemon is unavailable

When `daemonEnabled = true` (default) but JarvisBrainDaemon is not running:

1. `startBrainServer()` calls `DaemonManager.shared.checkDaemonHealth()`.
2. If health check fails: `AppState.daemonUnavailable = true` is set.
3. `_startLocalBrainContextServer()` is called — starts MacBrainServer for camera + brain-context HTTP on loopback only.
4. **Port 8765 is NOT bound.** Cross-device features (Android, Windows) are unavailable until the daemon starts.
5. `DaemonAppBridge` retries its WebSocket reconnect loop independently.
6. When the daemon becomes available, `DaemonAppBridge` reconnects and `AppState.daemonUnavailable` is set back to false.

The Mac app **never** falls through to hosting an external WebSocket server as a daemon substitute. The legacy `legacyBrainServerEnabled` preference is kept for JSON backward compatibility only and has no effect.

---

## Legacy bridge classes

Two classes are deprecated and inert:

- **`GatewayAndroidConnector`** (`Mac/JarvisMac/MacBrain/`) — marked `@available(*, deprecated)`. Was the old in-app Android WebSocket acceptor. External WebSocket hosting is now owned by JarvisBrainDaemon.
- **`MacBridgeProtocolV2`** (`Mac/JarvisMac/DistributedBrain/`) — marked `@available(*, deprecated)`. Was the old in-app Windows WebSocket + SSE server. Now replaced by JarvisBrainDaemon's `/v2/ws` endpoint.

Neither class is instantiated in any production code path. Both files remain in the codebase for source history only.

---

## Windows pairing

Windows clients use a two-step flow served entirely by JarvisBrainDaemon:

### Step 1 — Request pairing code (Mac app → daemon)
```
POST http://127.0.0.1:8765/v1/windows/pair/code
Authorization: Bearer <gateway-token>
→ { "code": "482916", "expiresAt": "2026-05-24T12:05:00Z" }
```
Code expires in 5 minutes.

### Step 2 — Exchange code (Windows → daemon)
```
POST http://[mac-ip]:8765/v1/windows/pair
Body: { "code": "482916", "deviceId": "my-pc", "deviceName": "My Windows PC" }
→ { "deviceToken": "<opaque>" }
```
The resulting `deviceToken` has `platform = "windows"` in the device registry.

### Step 3 — Connect WebSocket
```
GET ws://[mac-ip]:8765/v2/ws
Headers:
  Authorization: Bearer <deviceToken>
  Upgrade: websocket
  X-Platform: windows
```

---

## Auth file

- **Path**: `~/Library/Application Support/JarvisMac/gateway_paired_devices.json`
- **Writer**: `DaemonAuthStore` in JarvisBrainDaemon (single writer, `NSLock` protected)
- **Writes**: Atomic (`.atomic` option on `Data.write`)
- **Corruption recovery**: `load()` detects invalid JSON → backs up to `.json.bak` → starts with empty registry → logs error via `os_log`
- **Token security**: raw tokens never written to disk; only SHA-256 hashes are persisted

---

## Protocol Version

Protocol version: 2 (envelope-based routing via DaemonMessageEnvelope)

Clients send flat JSON frames. Daemon wraps them in DaemonMessageEnvelope before routing.
Mac app sends and receives DaemonMessageEnvelope-wrapped frames via DaemonAppBridge.

---

## Port Map

| Port | Process | Purpose |
|------|---------|---------|
| 8765 | JarvisBrainDaemon | Public WebSocket + HTTP API |
| 8766 | JarvisBrainDaemon (alt) | Internal IPC (JARVIS_DAEMON_PORT override) |
| loopback only | JarvisMac MacBrainServer | Camera stream + brain context HTTP |

---

## Devices and Roles

| Device | Primary role |
|--------|-------------|
| Android | Voice capture, STT, wake word, tool execution, notifications bridge |
| JarvisBrainDaemon | Routing, presence inference, handoff store, diagnostics, job scheduling |
| Mac | LLM reasoning, TTS, overlay rendering, memory, proactivity |
| Windows (sidecar) | Perception surface, browser/UI execution (Sprint P7+) |

---

## Latency Instrumentation

Every voice command pipeline stage is timed from Android STT through daemon routing
to Mac LLM completion and back. Key metrics:

| Metric | Source | Description |
|--------|--------|-------------|
| transcript_sent | Android LatencyTracker | Android STT final → daemon send |
| daemon_received | DaemonDiagnostics | Time daemon received transcript frame |
| daemon_routed | DaemonDiagnostics | Daemon internal route duration |
| reply_generated | Mac LatencyTracker | LLM start → complete |
| daemon_rtt | DaemonDiagnostics | WebSocket ping/pong round-trip |
| total_roundtrip | DaemonDiagnostics | Transcript sent → Android reply received |

Diagnostics are exposed at `GET /v1/diagnostics` (daemon HTTP endpoint).
No raw transcript text is ever logged — only durations and stage timestamps.

---

## Cross-Device Continuity (Handoff)

Users can move context between devices with natural commands:
- "Continue this on the Mac"
- "Show this on Android"
- "Send this to my Mac"

Flow:
1. Android recognises phrase via `FederationHandoffTool` regex patterns
2. Android sends `handoff.request` frame to daemon with key + value
3. Daemon routes to target device, stores in `HandoffContextStore` (20 entries, 24h TTL)
4. Mac `HandoffCoordinator` receives it:
   - URL key → opens in browser (NSWorkspace)
   - text key → writes to clipboard + sets `pendingHandoffText` for overlay display
   - conversation key → sets `pendingHandoffText` (conversation summary, not stored in clipboard)
5. Mac shows `HandoffNoticeView` overlay if text content received
6. `handoff.result` frame sent back to source device as confirmation

Daemon exposes recent handoffs at `GET /v1/handoffs`.

---

## Presence Inference Engine

`PresenceInferenceEngine` (daemon) computes confidence-scored user states from
raw `PresenceStore` data without persisting them. States: probablyDriving,
probablySleeping, probablyInMeeting, probablyAvailable, unknown.

Consumers:
- `ToolArbitrationService` — picks best device + output modality per tool
- `DaemonJobScheduler` — suppresses jobs during sleep/driving/quiet hours
- `DecisionEngine` (Mac app) — defers PASSIVE proactive suggestions

---

## Daemon Services

| Service | File | Purpose |
|---------|------|---------|
| PresenceInferenceEngine | JarvisBrainDaemon | Confidence-scored user state inference |
| DaemonJobScheduler | JarvisBrainDaemon | Recurring jobs with quiet hours + backoff |
| ToolArbitrationService | JarvisBrainDaemon | Best device/modality per tool invocation |
| DaemonTimeline | JarvisBrainDaemon | 500-event ring buffer of cross-device events |
| HandoffContextStore | JarvisBrainDaemon | Recent handoffs, 20 entries, 24h TTL |
| DaemonOfflineQueue | JarvisBrainDaemon | 50-message bounded queue with 120s TTL |
| PresenceStore | JarvisBrainDaemon | Per-device presence, 50-entry cap, 5min stale eviction |

---

## Android Voice Pipeline

```
WakeWordDetector
    │ onDetected
    ▼
JarvisStateMachine: WakeDetected → Listening
    │ SpeechCapture.listen()
    ▼
JarvisStateMachine: Processing
    │ FollowUpCoordinator → IntentClassifier → ToolRegistry
    │   (or LlmRouter for free-form)
    ▼
TtsEngine.speak()  ── interruptible by BargeInDetector
    │
    ▼
JarvisStateMachine: IdleWake → loop
```

`LatencyTracker` instruments every stage. `transcript.final` frames carry a
`correlationId` that the Mac echoes in its reply for roundtrip measurement.

---

## Mac Voice Pipeline

```
WakeWordService (Sherpa ONNX or Apple)
    │  wake event
    ▼
JarvisController.handleWakeEvent()
    │  ExecutionTracer.begin()
    ▼
SpeechRecognizer (Whisper or Apple Speech)
    │  transcript String
    ▼
ConversationRuntime.handleTranscript()
    │  follow-up resolution, conversation state
    ▼
CommandPhraseMatcher  →  IntentMapping  →  Intent?   (Tier 1)
    │
IntentRouter.route(parsed:)                           (Tier 2)
    │
LLMIntentBridge → LLMRouter → MiniMax | llama.cpp   (Tier 3)
    │
JarvisController.execute()
    ├──► TextToSpeechService.speak()
    └──► OverlayManager.open(kind:)
```

---

## Mac Subsystem Startup Order

`RuntimeCoordinator.shared` starts subsystems in topological order, polls health
every 30 seconds, and recovers failed subsystems independently (max 3 retries).

| Order | Runtime | Depends on |
|-------|---------|-----------|
| 10 | SystemRuntime | — |
| 20 | MemoryRuntime | system |
| 25 | BrainRuntime | memory |
| 30 | AudioRuntime | system |
| 40 | ConversationRuntime | audio, system |
| 50 | OverlayRuntime | system |
| 60 | AmbientRuntime | system, overlay |
| 70 | LLMRuntime | system, memory |
| 80 | ProactivityRuntime | system, overlay, conversation |
| 90 | AndroidRuntime | system |

---

## Android Reconnect and Status

`sharedStatus` state machine:

```
Disconnected → Connecting → Connected → Reconnecting → Connected
```

- `NetworkChangeObserver` triggers reconnect on network transitions
- Each reconnect starts exactly one heartbeat loop
- `DaemonMessageRouter` logs "client registered" on each successful connect

---

## Memory Architecture

### Mac
| Component | Description |
|-----------|-------------|
| `MemoryStore` | CRUD SQLite via GRDB — facts, conversation summaries, preferences |
| `BrainMemoryStore` | Authoritative long-term intelligence; importance × confidence scoring |
| `SemanticMemoryIndex` | NLEmbedding cosine similarity, 500-entry cap, persisted JSON |
| `EpisodeStore` | Time-bounded session grouping |
| `HandoffContextStore` | Cross-device handoff entries (daemon-side) |

### Android
| Component | Description |
|-----------|-------------|
| Room DB (`jarvis.db`) | Memory, conversation turns, knowledge, telemetry |
| EncryptedSharedPreferences | API keys, OAuth tokens, user settings |

---

## Security Invariants

These invariants are enforced in code and must not be regressed:

- `comm.action.execute` always has `requiresConfirmation: true` — Android never auto-executes
- Phone numbers masked as `****last4` before any log or wire frame
- No raw transcript bodies stored by default — only summaries (max 200 chars)
- Dangerous file extensions blocked: app, dmg, exe, sh, command, pkg
- No direct app-to-app sockets — all traffic through daemon on port 8765
- No QR/token UI for pairing — pairing code flow only
- Handoff text and conversation summaries capped at 200 chars
- DaemonTimeline redacts 7+ consecutive digit runs (phone number patterns)

---

## Daemon HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /v1/diagnostics | Aggregate latency + routing stats |
| GET | /v1/handoffs | Recent handoff entries (HandoffContextStore) |
| GET | /v1/presence | Current per-device presence snapshot |
| GET | /v1/health | Daemon liveness check |

---

## Troubleshooting

### Duplicate clients registered
Symptom: `DaemonMessageRouter` logs "client registered" twice for same device.
Cause: rapid reconnect before disconnect cleanup completes.
Fix: `unregisterClient` is idempotent. Check `DeviceRegistry.markDisconnected` is called.

### Daemon disconnected / banner stuck
Symptom: Mac shows "Daemon unavailable" banner even after daemon restarts.
Cause: `DaemonSleepWakeObserver` reconnect delay (2s) not triggered.
Fix: Check NSWorkspace wake notification reaches `DaemonAppBridge.connect()`.

### Stale presence routes
Symptom: `ToolArbitrationService` routes to a device that's offline.
Cause: `PresenceStore` entry not evicted (device disconnected >5min ago).
Fix: `evictStaleEntries()` runs on every `update()`. Verify `DeviceRegistry.connectedDevices` is current.

### High latency
Symptom: `daemon_rtt` > 200ms consistently.
Cause: Mac and Android on different networks (not local).
Fix: Ensure both devices are on the same LAN or Tailscale network.

### Missing Android notifications
Symptom: `comm.event.received` not arriving at daemon.
Cause: `JarvisNotificationListener` not granted notification access.
Fix: Settings → Notification Access → enable Jarvis.
