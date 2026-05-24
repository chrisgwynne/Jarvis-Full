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
