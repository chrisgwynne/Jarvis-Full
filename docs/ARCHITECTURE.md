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
