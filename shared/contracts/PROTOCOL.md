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

## Remote Actions (Android → Mac)

Remote actions let Android trigger discrete Mac-side operations via the daemon.

### remote.action.request (Android → daemon → Mac)
```json
{
  "type": "remote.action.request",
  "requestId": "<uuid>",
  "routeId": "<uuid>",
  "sourceDeviceId": "android",
  "targetPlatform": "mac",
  "action": "open_app",
  "parameters": { "appName": "Notes" },
  "userVisibleText": "Opening Notes on the Mac.",
  "requiresConfirmation": false,
  "timestamp": 1716000000000
}
```

Supported actions: `open_app`, `create_note`, `show_camera`, `open_jarvis`.

### remote.action.result (Mac → daemon → Android)
```json
{
  "type": "remote.action.result",
  "requestId": "<same uuid>",
  "routeId": "<same uuid>",
  "targetDeviceId": "android",
  "success": true,
  "spokenSummary": "Opening Notes on the Mac.",
  "timestamp": "2026-05-24T12:00:00Z"
}
```

On failure: `errorCode` and `errorMessage` are included. Error codes:
- `mac_client_unavailable` — Mac not connected
- `mac_action_timeout` — no response within 30s
- `unsupported_action` — action not implemented
- `unsupported_app` — app not found/installed
- `needs_more_info` — action succeeded partially (e.g. Notes opened but note title needed)

RemoteActionRouter (daemon) tracks pending requests with 30s timeout.
If Mac is offline when a request arrives, the daemon immediately returns
`mac_client_unavailable` to Android.

---

## File Transfer (Android → Mac)

Files are transferred via HTTP multipart upload; the Mac app downloads via HTTP.
The daemon acts as a temporary store (1-hour expiry, SHA-256 verified).

### 1. Upload (Android → daemon HTTP)
```
POST /v1/files/upload
Authorization: Bearer <token>
Content-Type: multipart/form-data; boundary=JarvisFileBoundary
X-Device-Id: android

[multipart body with file part + metadata fields]
Metadata fields: targetPlatform, openOnMac, suggestedAction, userVisibleName
```
Response: `{ "transferId": "...", "filename": "...", "sha256": "...", "expiresAt": "..." }`

### 2. Daemon notifies Mac (daemon → Mac via WebSocket)
`file.transfer.created` envelope sent automatically after upload.

### 3. Mac downloads (Mac → daemon HTTP)
```
GET /v1/files/<transferId>
Authorization: Bearer <token>
X-Platform: mac
```
Response: binary file with `X-SHA256` header for verification.

### 4. Mac deletes after pickup
```
DELETE /v1/files/<transferId>
Authorization: Bearer <token>
```

Security:
- Blocked extensions: `.app`, `.dmg`, `.exe`, `.sh`, `.command`, `.pkg`, etc.
- Allowed MIME type prefixes: `image/`, `video/`, `audio/`, `text/`, `application/pdf`, etc.
- Max file size: 100 MB (configurable via `JARVIS_MAX_FILE_MB` env var)
- `localTempPath` is NEVER included in any HTTP response or log statement
- Only Mac (`X-Platform: mac`) can download files

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

---

## Phase 5–9 Frame Families

The following frame types were added to support cross-device platform features.

### presence.update
Sent by any device to update its presence state in the daemon's `PresenceStore`.
```json
{
  "type": "presence.update",
  "target": {"type": "daemon"},
  "payload": {
    "isListening": false,
    "isSpeaking": false,
    "isScreenLocked": false,
    "isAppForeground": true,
    "hasHeadset": true,
    "batteryPercent": 82,
    "isCharging": false,
    "activityState": "stationary",
    "focusMode": "normal"
  }
}
```

### context.update
Sent by any device to write a key/value pair into the daemon's `ContextStore` (24h TTL).
```json
{
  "type": "context.update",
  "target": {"type": "daemon"},
  "payload": {"key": "last_transcript", "value": "turn off the kitchen lights"}
}
```

### notification.forward
Sent by Android to the daemon; daemon forwards to Mac.
```json
{
  "type": "notification.forward",
  "target": {"type": "macApp"},
  "payload": {
    "packageName": "com.slack.android",
    "appName": "Slack",
    "title": "Chris in #general",
    "text": "Can you check the PR?",
    "postedAt": "2026-05-24T10:00:00Z"
  }
}
```

### comm.event.received
Sent by Android when a missed call, unread SMS, or WhatsApp message is detected.
```json
{
  "type": "comm.event.received",
  "target": {"type": "daemon"},
  "payload": {
    "eventId": "evt_abc123",
    "channel": "phone",
    "direction": "incoming",
    "contactName": "Alice",
    "contactHandle": "****1234",
    "receivedAt": "2026-05-24T09:55:00Z",
    "sourceApp": "com.android.dialer"
  }
}
```
`channel` is one of: `phone` | `sms` | `whatsapp` | `whatsapp_business`.
Phone numbers are ALWAYS masked to `****last4` before transmission.

### comm.event.resolved
Sent by Android when a comm event is resolved (user replied/called back outside Jarvis).
```json
{
  "type": "comm.event.resolved",
  "target": {"type": "daemon"},
  "payload": {"eventId": "evt_abc123", "state": "replied"}
}
```

### proactive.comm.prompt
Sent by daemon to Mac when a comm event is ready for proactive prompting.
```json
{
  "type": "proactive.comm.prompt",
  "target": {"type": "macApp"},
  "payload": {
    "eventId": "evt_abc123",
    "channel": "phone",
    "contactName": "Alice",
    "contactHandle": "****1234",
    "promptText": "Alice called while you were away.",
    "promptCount": 1
  }
}
```

### comm.action.request
Sent by Mac to daemon to request an action on a comm event.
```json
{
  "type": "comm.action.request",
  "target": {"type": "android", "deviceId": "pixel-7a"},
  "payload": {
    "requestId": "req_xyz",
    "eventId": "evt_abc123",
    "contactName": "Alice",
    "channel": "phone",
    "action": "callBack",
    "requiresConfirmation": true
  }
}
```
`action` is one of: `callBack` | `reply` | `summarise` | `remindLater` | `dismiss`.

### comm.action.execute
Forwarded by daemon to Android. Android MUST show confirmation UI before executing.
Same payload shape as `comm.action.request`.

### comm.action.result
Sent by Android to daemon after user confirms and action completes.
```json
{
  "type": "comm.action.result",
  "target": {"type": "macApp"},
  "payload": {
    "requestId": "req_xyz",
    "eventId": "evt_abc123",
    "action": "callBack",
    "success": true,
    "message": "Calling Alice..."
  }
}
```

### handoff.request
Sent by any device to hand off text, URL, file, or conversation context to another device.
```json
{
  "type": "handoff.request",
  "target": {"type": "android"},
  "payload": {
    "key": "url",
    "value": "https://example.com/article",
    "sourceDevice": "mac"
  }
}
```
`key` is one of: `text` | `url` | `file` | `conversation`.

### handoff.result
Sent by the receiving device back to the sender.
```json
{
  "type": "handoff.result",
  "target": {"type": "macApp"},
  "payload": {"key": "url", "success": true, "sourceDevice": "android"}
}
```

### clipboard.update
Sent by a device to explicitly push clipboard content to another device.
Must be explicitly triggered by user — never sent silently.
```json
{
  "type": "clipboard.update",
  "target": {"type": "android"},
  "payload": {"text": "Meeting notes for Thursday", "sourceDevice": "mac"}
}
```

---

## New daemon HTTP endpoints (Phase 5–9)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/devices/presence` | Returns array of per-device presence snapshots |
| GET | `/v1/context` | Returns all active context store entries |
| GET | `/v1/watchdog/status` | Returns all active (unresolved) comm events |
| GET | `/v1/diagnostics` | Aggregate latency + routing stats |
| GET | `/v1/handoffs` | Recent handoff entries (HandoffContextStore) |

---

## Latency Trace

No new wire frames are added for latency. Timing is recorded locally on each device
and correlated by `correlationId` in `DaemonMessageEnvelope`. The daemon exposes
aggregate diagnostics at `GET /v1/diagnostics`.

Key `correlationId` usage:
- Android sets `correlationId` on `transcript.final` frames
- Mac echoes the same `correlationId` in its reply frames
- Daemon uses this to correlate request/reply for roundtrip measurement
