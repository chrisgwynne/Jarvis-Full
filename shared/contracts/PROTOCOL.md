# Cross-Device WebSocket Protocol

## Architecture

**JarvisBrainDaemon** is the permanent Jarvis runtime. It is the sole WebSocket authority.
All client apps connect to the daemon. Apps are disposable frontends.

```
JarvisBrainDaemon (port 8765)
├── Android (client)  → /v1/android/ws or /v2/ws
├── Windows (client)  → /v2/ws
├── Mac app (client)  → /v1/mac/ws
```

The daemon:
- Owns port 8765
- Owns pairing/auth
- Owns device registry
- Owns routing
- Routes transcript.final → Mac app (brain intelligence)
- Routes reply.final → originating device
- Survives all app restarts

The Mac app:
- Connects to daemon at ws://127.0.0.1:8765/v1/mac/ws
- Processes transcripts through the brain pipeline
- Sends replies back through daemon
- Is the intelligence engine, not the routing authority

---

## Pairing flow

### 1. Generate code (Mac app → daemon)
```
POST http://127.0.0.1:8765/v1/android/pair/code    (for Android)
POST http://127.0.0.1:8765/v1/windows/pair/code   (for Windows)
→ { "code": "482916", "expiresAt": "2026-05-24T12:05:00Z" }
```
Mac app displays the code. Code expires in 5 minutes.

### 2. Exchange code (client → daemon)
```
POST http://[daemon-host]:8765/v1/android/pair
Body: { "code": "482916", "deviceId": "pixel-8-pro", "deviceName": "My Phone" }
→ { "sessionToken": "<opaque>" }
```

### 3. Connect WebSocket
```
GET ws://[daemon-host]:8765/v2/ws
Headers:
  Authorization: Bearer <sessionToken>
  Upgrade: websocket
  X-Platform: android   (or windows)
```

---

## WebSocket routes

| Route | Platform | Notes |
|-------|----------|-------|
| `/v2/ws` | All | Canonical unified route |
| `/v1/android/ws` | Android | Platform alias |
| `/v1/windows/ws` | Windows | Platform alias (compat) |
| `/v1/mac/ws` | Mac app | Internal Mac connection |

---

## Frame types

### Client → Daemon

| Type | Description |
|------|-------------|
| `transcript.final` | Complete STT result for Mac brain processing |
| `transcript.partial` | Streaming partial (best-effort, not queued) |
| `device.hello` | First frame; identifies device/platform/version |
| `heartbeat` | Keep-alive; daemon replies with `heartbeat.ack` |
| `presence.update` | Device context (active app, window, etc.) |
| `execution.result` | Result of a Mac-dispatched tool execution |
| `capability.update` | Update device capability list |

### Daemon → Client

| Type | Description |
|------|-------------|
| `reply.final` | Complete brain reply targeting originating device |
| `reply.partial` | Streaming token chunk |
| `orchestrate.speak` | Request device to speak text via its TTS |
| `orchestrate.silent` | Request device to suppress local TTS |
| `proactive.notify` | Push notification from Mac brain |
| `heartbeat.ack` | Response to heartbeat |
| `hello.ack` | Acknowledges device.hello |
| `nack` | Routing failure (brain unavailable, no target device) |
| `error` | Protocol or processing error |

---

## Key frame schemas

### transcript.final (client → daemon)
```json
{
  "type": "transcript.final",
  "messageId": "<uuid>",
  "transcript": "turn on the kitchen lights",
  "deviceId": "pixel-8-pro",
  "timestamp": 1716000000000
}
```

### reply.final (daemon → client, via Mac)
```json
{
  "type": "reply.final",
  "routeId": "<same as messageId>",
  "text": "Turning on the kitchen lights."
}
```

### orchestrate.speak (daemon → client)
```json
{
  "type": "orchestrate.speak",
  "text": "Your standup starts in five minutes."
}
```

### proactive.notify (daemon → client)
```json
{
  "type": "proactive.notify",
  "title": "Standup soon",
  "body": "Your 9am standup starts in five minutes.",
  "urgency": "high"
}
```

### heartbeat (client → daemon)
```json
{
  "type": "heartbeat",
  "deviceId": "pixel-8-pro",
  "timestamp": 1716000030000
}
```

### device.hello (client → daemon)
```json
{
  "type": "device.hello",
  "deviceId": "my-windows-pc",
  "deviceName": "Studio Laptop",
  "platform": "windows",
  "appVersion": "2.3.1",
  "protocolVersion": "2"
}
```

---

## Routing model

```
Android          Daemon              Mac app
   │                │                   │
   │─ transcript.final ──────────────────►│
   │                │                   │ (handleRemoteTranscript)
   │                │                   │ (brain pipeline)
   │◄─ reply.final ─────────────────────│
   │  (speaks it)   │                   │
```

If Mac app is offline when transcript arrives:
- Daemon queues the frame (DaemonOfflineQueue, replay-safe types only)
- Mac app receives the queue drain on reconnect
- Daemon sends `nack { reason: "brain_unavailable" }` to originating device

---

## Auth file ownership

| Process | File |
|---------|------|
| JarvisBrainDaemon (port 8765) | `~/Library/Application Support/JarvisMac/gateway_paired_devices.json` |

The daemon is the sole auth authority. JarvisMac reads device state via daemon HTTP API.

---

## Windows pairing endpoints

Windows clients use the same two-step flow as Android, served by JarvisBrainDaemon:

```
POST /v1/windows/pair/code   → { "code": "482916", "expiresAt": "…" }
POST /v1/windows/pair        → { "deviceToken": "<opaque>" }
```

The `/v1/windows/pair/code` endpoint was added alongside the existing `/v1/android/pair/code` endpoint. The pairing code is generated by `DaemonAuthStore.generatePairingCode()` and expires in 5 minutes. After pairing, the device has `platform = "windows"` in the registry.

---

## Mac app never binds port 8765

The Mac app (`JarvisMac`) is a **client** of JarvisBrainDaemon. It:
- Connects as a client to `ws://127.0.0.1:8765/v1/mac/ws`
- Starts MacBrainServer on loopback only for camera + brain-context HTTP (a separate, local-only service)
- **Never** binds port 8765

When the daemon is unavailable, `AppState.daemonUnavailable = true` is surfaced in the UI. The Mac app does not fall back to hosting a public WebSocket server.

---

## Deprecated classes (do not use)

- `GatewayAndroidConnector` — was the old in-app Android WebSocket acceptor. Marked `@available(*, deprecated)`. Inert.
- `MacBridgeProtocolV2` — was the old in-app Windows WebSocket/SSE server. Marked `@available(*, deprecated)`. Inert.

Both are replaced by JarvisBrainDaemon's `/v1/android/ws`, `/v1/windows/ws`, and `/v2/ws` endpoints.
