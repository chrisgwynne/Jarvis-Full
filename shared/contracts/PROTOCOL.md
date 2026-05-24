# Cross-Device WebSocket Protocol

Mac Brain (JarvisMac) owns port **8765** and exposes three WebSocket endpoints:

| Route | Client | Purpose |
|-------|--------|---------|
| `/v2/ws` | Windows | Full bidirectional bridge (MacBridgeProtocolV2) |
| `/v1/windows/ws` | Windows | Compat alias → same MacBridgeProtocolV2 handler |
| `/v1/android/ws` | Android | Android bidirectional bridge (GatewayAndroidConnector) |

JarvisBrainDaemon listens on port **8766** (internal IPC only; clients never connect here directly).

---

## Frame envelope

Every frame is a JSON text message (RFC 6455 opcode 0x01).

```json
{
  "type": "<frame-type>",
  ...payload fields
}
```

---

## Client → Mac frame types

### `transcript.final`
Client has a complete utterance for the Mac brain to process.

```json
{
  "type": "transcript.final",
  "messageId": "<uuid>",
  "transcript": "turn on the kitchen lights",
  "deviceId": "android-device-name",
  "timestamp": 1716000000000
}
```

Fields:
- `messageId` — caller-generated UUID; echoed back in `reply.final.routeId`
- `transcript` — the spoken text, already STT-processed
- `deviceId` — stable identifier for this device
- `timestamp` — Unix epoch ms

### `transcript.partial`
Streaming partial transcript (informational; Mac records but does not process).

```json
{
  "type": "transcript.partial",
  "messageId": "<uuid>",
  "transcript": "turn on the",
  "deviceId": "android-device-name"
}
```

### `presence.update` (Windows)
Windows presence snapshot pushed to Mac.

```json
{
  "type": "presence.update",
  "deviceId": "windows-pc",
  "activeApp": "cursor",
  "windowTitle": "JarvisRuntime.kt — Jarvis-Full",
  "activeCodingFile": "JarvisRuntime.kt",
  "browserURL": "",
  "foregroundApp": "cursor"
}
```

### `lease.request` (Windows)
Request TTS speaker lease from Mac.

```json
{
  "type": "lease.request",
  "deviceId": "windows-pc",
  "speechId": "<uuid>"
}
```

### `device.hello`
First frame after WebSocket upgrade; identifies device.

```json
{
  "type": "device.hello",
  "deviceId": "my-windows-pc",
  "deviceName": "Studio Laptop",
  "platform": "windows",
  "appVersion": "2.3.1"
}
```

### `replay.begin` / `replay.end` (Windows)
Brackets a block of history replay frames. Mac ingests but does not produce live responses.

```json
{ "type": "replay.begin" }
{ "type": "replay.end" }
```

### `execution.result` (Windows)
Result of a remote execution request dispatched by Mac.

```json
{
  "type": "execution.result",
  "requestId": "<uuid>",
  "ok": true,
  "status": "done",
  "message": "",
  "payload": {}
}
```

### `heartbeat`
Keep-alive ping. Mac ignores but records the timestamp.

```json
{
  "type": "heartbeat",
  "deviceId": "android-device-name",
  "timestamp": 1716000000000
}
```

---

## Mac → Client frame types

### `reply.final`
Complete response to a `transcript.final` request.

```json
{
  "type": "reply.final",
  "routeId": "<same uuid as transcript.final messageId>",
  "text": "Turning on the kitchen lights."
}
```

### `reply.partial`
Streaming token chunk (before `reply.final` arrives).

```json
{
  "type": "reply.partial",
  "routeId": "<uuid>",
  "text": "Turning on"
}
```

### `orchestrate.speak`
Mac requests the client to speak this text using its local TTS.

```json
{
  "type": "orchestrate.speak",
  "text": "Good morning. Your 9am standup starts in five minutes."
}
```

### `orchestrate.silent`
Mac requests the client to suppress its local TTS for the current turn.

```json
{
  "type": "orchestrate.silent",
  "reason": "mac_speaking"
}
```

### `proactive.notify`
Mac pushes a proactive notification to the client.

```json
{
  "type": "proactive.notify",
  "title": "Standup in 5 minutes",
  "body": "Your 9am standup starts in five minutes.",
  "urgency": "high"
}
```

### `session.start`
Sent immediately after WebSocket upgrade to confirm connection.

```json
{
  "type": "session.start",
  "sessionId": "<uuid>",
  "serverVersion": "mac-brain-1.0"
}
```

### `lease.grant` / `lease.denied` (Windows)
Response to a `lease.request`.

```json
{ "type": "lease.grant",  "speechId": "<uuid>" }
{ "type": "lease.denied", "speechId": "<uuid>", "reason": "mac_owns_speaker" }
```

### `hello.ack` (Windows)
Acknowledges a `device.hello`.

```json
{
  "type": "hello.ack",
  "deviceId": "my-windows-pc",
  "sessionId": "<uuid>"
}
```

---

## Pairing flow

### Step 1 — Generate code (on Mac)
```
POST /v1/windows/pair/code   (or /v1/android/pair/code)
→ { "code": "482916" }
```

### Step 2 — Exchange code (from client)
```
POST /v1/windows/pair        (or /v1/android/pair)
Body: { "code": "482916", "deviceId": "...", "deviceName": "..." }
→ { "sessionToken": "<opaque-token>" }
```

### Step 3 — Connect WebSocket
```
GET /v2/ws   (Windows)  or  GET /v1/android/ws  (Android)
Headers: Authorization: Bearer <sessionToken>
         Upgrade: websocket
```

---

## Auth file ownership

| Process | Auth file |
|---------|-----------|
| `JarvisMac` (port 8765) | `~/Library/Application Support/JarvisMac/gateway_paired_devices.json` |
| `JarvisBrainDaemon` (port 8766) | `~/Library/Application Support/JarvisMac/daemon_paired_devices.json` |

Client-facing auth always goes through JarvisMac. The daemon file is for internal daemon-managed pairings only.
