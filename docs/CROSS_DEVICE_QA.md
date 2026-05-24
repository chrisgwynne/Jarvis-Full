# Cross-Device QA Script

Manual QA for the daemon-centric architecture.
JarvisBrainDaemon must be running before any client can connect.

---

## Prerequisites

| Item | Check |
|------|-------|
| JarvisBrainDaemon running on Mac | `curl http://localhost:8765/health` → `{"status":"ok"}` |
| JarvisMac running | Connects to daemon at ws://127.0.0.1:8765/v1/mac/ws |
| Android device on same network | Jarvis app installed |
| Windows PC (optional) | Jarvis Windows app installed |

---

## 1 — Daemon health

```
curl http://localhost:8765/health
```
Expected: `{"status":"ok","daemon":true}`

---

## 2 — Mac app connects to daemon

1. Launch JarvisBrainDaemon (must be first).
2. Launch JarvisMac.
3. Check daemon diagnostics: `curl http://localhost:8765/v1/diagnostics`
4. Expected: `connectedMacClients: 1` in router diagnostics.

---

## 3 — Android pairing

1. Mac app: Settings → Mac Integration → "Generate Code".
   Internally: `POST http://127.0.0.1:8765/v1/android/pair/code` → displays code.
2. Android: Settings → Mac Integration → enter URL `http://[mac-ip]:8765` and 6-digit code.
3. Android POSTs `http://[mac-ip]:8765/v1/android/pair`.
4. Expected: Android status shows "Paired" within 3s.
5. Verify: `curl -H "Authorization: Bearer <token>" http://localhost:8765/v1/devices` shows new device.

---

## 4 — Android STT → Mac brain → Android TTS

1. Android paired and connected (status = Connected).
2. Trigger voice: "What time is it?"
3. Log checks:
   - Android: `[TRANSCRIPT_RAW]`
   - Android: `sendTranscript:` log
   - Android: machine transitions to Listening (local processing skipped)
   - Daemon: `WS [android] type=transcript.final`
   - Daemon router: `type=transcript.final → macApp`
   - Mac: `DaemonAppBridge: received type=transcript.final`
   - Mac: `handleRemoteTranscript` runs brain pipeline
   - Mac: `DaemonAppBridge.sendReply()` sends `reply.final`
   - Daemon: `type=reply.final → android`
   - Android: `onReplyFinal` fires → `speakAndRecord()`
4. Expected: Android TTS speaks the reply.

---

## 5 — Windows STT → Mac brain → Windows TTS

1. Windows connected to daemon at `/v2/ws`.
2. Trigger voice command.
3. Expected: daemon routes transcript to Mac, Mac replies, Windows speaks.

---

## 6 — Mac app restart

1. Quit JarvisMac while Android is connected.
2. Android sends a transcript.
3. Daemon queues it (offline queue).
4. Relaunch JarvisMac.
5. Expected: Mac connects to daemon, offline queue drains, Mac processes queued transcript.

---

## 7 — Daemon restart

1. Kill daemon while all clients connected.
2. Android/Windows: status transitions to Reconnecting.
3. Restart daemon.
4. Clients reconnect automatically.
5. Expected: after reconnect, full voice round-trip works again.

---

## 8 — Disconnect behavior

1. Disconnect Android from network.
2. Daemon: Android client removed on ping failure.
3. Send transcript from Windows: routed to Mac, Mac replies, Windows speaks (no Android interference).
4. Reconnect Android: Android reconnects and re-authenticates.

---

## Log grep targets

| Event | Platform | Tag / string |
|-------|----------|--------------|
| Daemon ready | Daemon | `JarvisBrainDaemon listening on port 8765` |
| Mac connected | Mac | `DaemonAppBridge: connected to daemon` |
| Transcript sent | Android | `sendTranscript:` |
| Transcript received | Daemon | `WS [android] type=transcript.final` |
| Routed to Mac | Daemon | `router: received type=transcript.final` |
| Mac processes | Mac | `handleRemoteTranscript` |
| Reply sent | Mac | `DaemonAppBridge send` |
| Reply received | Android | `onReplyFinal` |
| Android speaks | Android | `[AUDIO_FOCUS_REQUEST] speakAndRecord` |
| Port conflict | Daemon | listen error on 8765 |
