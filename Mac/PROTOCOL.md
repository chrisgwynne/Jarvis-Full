> This file mirrors the canonical docs at `../docs/ARCHITECTURE.md` and
> `../shared/contracts/PROTOCOL.md`. See those files for the current specification.

---

# Jarvis Cross-Device Protocol

## Message Envelope Format

All messages between daemon and clients use `DaemonMessageEnvelope`:

```json
{
  "type": "transcript.final",
  "messageId": "<uuid>",
  "deviceId": "<device-id>",
  "seq": 42,
  "ts": 1700000000.0,
  "payload": { ... }
}
```

## Pairing Flow

### Device → Daemon

1. Device requests a pairing code: `GET /v1/{platform}/pair/code`
2. User receives a 6-digit code (valid 5 minutes)
3. Device submits code: `POST /v1/{platform}/pair` with `{ "code": "123456", "deviceId": "...", "name": "..." }`
4. On success: daemon returns a scoped device token (raw, one-time only)
5. Device stores token; daemon stores only SHA-256 hash

### Token Storage

- Device: stores raw token in device secure storage
- Daemon: stores `tokenHash = SHA-256(rawToken)` in `gateway_paired_devices.json`
- Raw token is never persisted by the daemon, never logged, never sent in diagnostics

## Auth Token Security

- Device tokens are stored as SHA-256 hashes only (`tokenHash` field in `gateway_paired_devices.json`)
- Raw tokens are NEVER persisted to disk, never logged, never sent in diagnostics
- On corrupt JSON: daemon backs up the file, starts with empty registry, logs error without any token values
- Gateway token (for Mac app itself) stored in macOS Keychain only

## Offline Queue Behaviour

When the Mac app client disconnects from the daemon:
- Replay-safe messages are queued (max 50, max 120s age)
- Replay-unsafe messages are silently dropped (no re-execution risk)
- On reconnect: daemon drains the queue and delivers messages in FIFO order
- `drainedCount` tracks total messages successfully delivered for diagnostics

### Replay-Safe Types (queued when Mac is offline)

| Type | Rationale |
|------|-----------|
| `transcript.final` | User voice; Mac interprets late (acceptable) |
| `execution.result` | Past Android result; Mac resolves continuation |
| `tool.result` | Legacy alias for execution.result |
| `command.result` | Legacy alias for execution.result |
| `error.report` | Informational; no action required |
| `android.event` | Phone events (calls, SMS, battery); informational |

### Replay-Unsafe Types (dropped when Mac is offline)

| Type | Rationale |
|------|-----------|
| `execution.request` | Would re-execute Android capability (destructive!) |
| `orchestrate.speak` | Time-sensitive; stale TTS is confusing |
| `orchestrate.silent` | Ordering signals; meaningless when stale |
| `reply.final` / `reply.partial` | Already-answered turns; replaying is disorienting |
| `presence.update` | Ephemeral sensor data; stale presence is wrong |
| `transcript.partial` | Ephemeral ASR intermediate; meaningless after session ends |
| `proactive.notify` | Time-sensitive; stale alerts are alarming |
| `heartbeat.*` / `ping` / `pong` | Transport keep-alive; never meaningful to queue |

## WebSocket Protocol

### Android WebSocket

- Endpoint: `wss://<host>:8765/v1/android/ws`
- Auth: `Authorization: Bearer <device-token>` header on upgrade
- Messages: JSON frames following `DaemonMessageEnvelope`

### Windows WebSocket

- Endpoint: `wss://<host>:8765/v1/windows/ws`
- Auth: `Authorization: Bearer <device-token>` header on upgrade
- Messages: JSON frames following `DaemonMessageEnvelope`

### Mac App ↔ Daemon

- The Mac app connects as a client to `ws://localhost:8765/v1/mac/ws`
- Uses the gateway token (stored in macOS Keychain) for auth
- On Mac app restart: daemon replays queued messages after auth

## Proactive Notification Routing

Proactive events originate on the Mac (from `ProactivityOrchestrator`) and are routed by `GlobalProactivityCoordinator`:

1. Mac always receives high/critical urgency events directly
2. For Windows delivery, the Mac sends a `proactive.notify` message to the daemon
3. Daemon forwards to connected Windows clients via their WebSocket sessions
4. The Mac app never directly manages Windows WebSocket connections
