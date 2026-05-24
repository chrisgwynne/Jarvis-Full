# Jarvis macOS Architecture

## Overview

Jarvis runs as a macOS status-bar application (`JarvisMac`) alongside a privileged LaunchAgent daemon (`JarvisBrainDaemon`). The daemon owns port 8765 permanently — even when the Mac app is closed — so Android and Windows devices can always connect.

## Daemon-Centric Architecture

```
JarvisBrainDaemon (LaunchAgent, port 8765)
    ├─ Android WebSocket clients  (/v1/android/ws)
    ├─ Windows WebSocket clients  (/v1/windows/ws)
    └─ Mac app client             (connects as a client, not a server)

JarvisMac (Mac app)
    └─ DaemonClient: connects to JarvisBrainDaemon:8765
```

**Key principle**: `JarvisMac` never binds port 8765. It is always a client of `JarvisBrainDaemon`.

## Daemon-Unavailable UI (Limited Local Mode)

When JarvisBrainDaemon cannot be reached at startup:

1. `AppState.daemonUnavailable` is set to `true` in `JarvisController.startBrainServer()`
2. `DaemonControlView` shows an orange banner: "Jarvis daemon unavailable — running in limited local mode until the daemon reconnects."
3. The Mac app starts `_startLocalBrainContextServer()` (camera + brain-context HTTP only; never binds port 8765)
4. On reconnect, `daemonUnavailable` is cleared and the banner auto-dismisses

**What works in limited local mode:**
- All local voice commands, TTS, overlays
- Camera and brain context HTTP API (loopback only)
- Home Assistant, Calendar, Todoist, all local integrations

**What requires the daemon:**
- Android and Windows device connections
- Cross-device STT→Mac→TTS routing
- Offline message queue

## Offline Queue

`DaemonOfflineQueue` (in JarvisBrainDaemon) is a bounded in-memory queue for messages directed at the Mac app when it is temporarily offline:

- **maxDepth**: 50 messages (oldest dropped on overflow)
- **maxAgeSeconds**: 120 seconds (stale messages evicted on every operation)
- **drainedCount**: cumulative count of messages successfully delivered after reconnect

Replay-safe types (queued): `transcript.final`, `execution.result`, `tool.result`, `command.result`, `error.report`, `android.event`

Replay-unsafe types (dropped): `execution.request`, `orchestrate.speak`, `orchestrate.silent`, `reply.final`, `reply.partial`, `presence.update`, `transcript.partial`, `proactive.notify`, heartbeat variants

## Auth Corruption Recovery

`DaemonAuthStore` handles corrupt `gateway_paired_devices.json` gracefully:

1. Detects JSON decode failure
2. Backs up corrupt file to `gateway_paired_devices.json.bak`
3. Starts with empty device registry (no crash, no data loss of other data)
4. Logs error to OSLog (no token values ever logged)

## Daemon Test Target

`JarvisBrainDaemonTests` is a unit test bundle in `Mac/project.yml` that validates core daemon invariants:

- `DaemonAuthStore`: atomic save/load, concurrent reads, corrupt JSON recovery, no token values in logs
- `DaemonOfflineQueue`: caps at depth=50, age cap=120s, drainedCount accumulation, replay-unsafe types dropped, replay-safe types queued

## Proactivity Routing

`GlobalProactivityCoordinator` routes proactive events to the Mac orchestrator. Windows delivery is handled entirely by `JarvisBrainDaemon` — it pushes `proactive.notify` messages to connected Windows clients via its own authenticated WebSocket sessions. The Mac app never directly pushes to Windows clients.

## Key Source Files

| File | Purpose |
|------|---------|
| `JarvisBrainDaemon/DaemonAuthStore.swift` | Device auth + pairing, Keychain gateway token |
| `JarvisBrainDaemon/DaemonOfflineQueue.swift` | Bounded queue for offline Mac delivery |
| `JarvisBrainDaemon/DaemonMessageRouter.swift` | Routes messages between Android/Windows/Mac |
| `JarvisMac/Core/DaemonManager.swift` | LaunchAgent lifecycle (install/start/stop/poll) |
| `JarvisMac/UI/DaemonControlView.swift` | Settings UI for daemon status + limited-mode banner |
| `JarvisMac/DistributedBrain/GlobalProactivityCoordinator.swift` | Mac-side proactivity routing |
