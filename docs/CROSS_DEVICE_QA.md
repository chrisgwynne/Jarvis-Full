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

## 9 — Daemon unavailable: Mac shows diagnostic, not public port

**Scenario**: daemon is enabled in prefs but not running.

1. Ensure JarvisBrainDaemon is NOT running.
2. Launch JarvisMac.
3. Expected:
   - Mac logs: `[BrainGateway] JarvisBrainDaemon is not running. Cross-device features unavailable.`
   - `AppState.daemonUnavailable == true` (visible in Debug HUD if implemented)
   - MacBrainServer starts on loopback only (camera + brain-context HTTP)
   - Port 8765 is NOT bound by JarvisMac
4. Verify: `curl http://localhost:8765/health` returns connection refused (no daemon, no Mac server on 8765)
5. Start JarvisBrainDaemon.
6. Expected: Mac reconnects, `AppState.daemonUnavailable` clears to false.

---

## 10 — Windows pair flow using /v1/windows/pair/code + /v1/windows/pair

1. Mac app generates pairing code:
   ```
   POST http://127.0.0.1:8765/v1/windows/pair/code
   Authorization: Bearer <gateway-token>
   ```
   Expected: `{ "code": "NNNNNN", "expiresAt": "…" }` within 200ms.
2. Windows client uses code:
   ```
   POST http://[mac-ip]:8765/v1/windows/pair
   Body: { "code": "NNNNNN", "deviceId": "win-pc", "deviceName": "Studio" }
   ```
   Expected: `{ "deviceToken": "<opaque>" }`, HTTP 200.
3. Windows connects:
   ```
   GET ws://[mac-ip]:8765/v2/ws
   Authorization: Bearer <deviceToken>
   X-Platform: windows
   ```
   Expected: 101 Switching Protocols, daemon logs `Windows WS connected`.
4. Verify: `curl http://localhost:8765/v1/devices` shows new device with `platform: "windows"`.
5. Test voice round-trip from Windows: trigger STT → Mac replies → Windows TTS.

---

## 11 — Corrupt auth file: backup created, empty registry, log message

1. Stop JarvisBrainDaemon.
2. Write invalid JSON to `~/Library/Application Support/JarvisMac/gateway_paired_devices.json`:
   ```
   echo "CORRUPT DATA" > ~/Library/Application\ Support/JarvisMac/gateway_paired_devices.json
   ```
3. Start JarvisBrainDaemon.
4. Expected:
   - Log contains: `DaemonAuthStore: corrupt JSON — backed up to .bak, starting with empty registry`
   - A `.bak` file is created alongside the JSON file
   - Daemon starts successfully with no paired devices
   - All existing pairings are lost (expected — corrupt file is unrecoverable)
5. Pair a new device to verify the empty registry works correctly.

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
| Daemon unavailable | Mac | `[BrainGateway] JarvisBrainDaemon is not running` |
| Auth file corrupt | Daemon | `DaemonAuthStore: corrupt JSON — backed up to .bak` |
| Windows pair code | Daemon | request to `/v1/windows/pair/code` |
| Remote action request | Daemon | `remote-action: request routed to Mac` |
| Remote action result | Daemon | `remote-action: result routed to Android` |
| Mac unavailable nack | Daemon | `remote-action: Mac unavailable` |
| File upload | Daemon | `transfer: stored transferId=` |
| File download | Daemon | `transfer: delivered transferId=` |

---

## Remote Actions QA

### "Open Notes on the Mac"

1. Ensure Android and Mac are both connected to daemon.
2. Say "open notes on the mac" to Android Jarvis.
3. Expected:
   - Android sends `remote.action.request` with `action: "open_app"`, `appName: "Notes"`
   - Daemon routes to Mac via `RemoteActionRouter`
   - Mac opens Notes via `MacActionHandler.openApp`
   - Mac sends `remote.action.result` with `success: true` and spoken summary
   - Android TTS speaks "Opening Notes on the Mac." (from `onReplyFinal`)
4. Daemon log: `remote-action: request routed to Mac` then `remote-action: result routed to Android`

### "Create a note called Test on the Mac"

1. Say "create a note called Test on the mac" to Android Jarvis.
2. Expected:
   - `remote.action.request` with `action: "create_note"`, `parameters.title: "Test"`
   - Mac creates note via AppleScript in Notes app
   - Android speaks "Creating a note called Test on the Mac."
3. If automation permission not granted: Mac speaks "Notes is open. I couldn't create the note automatically."

### "Show Mac camera"

1. Say "show me the mac camera" to Android Jarvis.
2. Expected:
   - `remote.action.request` with `action: "show_camera"`
   - Mac returns `success: false, errorCode: "unsupported_action"`
   - Android speaks "That Mac action is not supported yet."

### "Put this on the Mac" (share sheet)

1. From any Android app (Photos, Chrome, Files), share a photo using the system share sheet.
2. Select "Send to Mac" from the share sheet.
3. Expected:
   - `JarvisShareActivity` receives the file
   - File POSTed to `/v1/files/upload` on daemon
   - Daemon sends `file.transfer.created` WebSocket event to Mac
   - Mac downloads file to `~/Downloads/Jarvis Transfers/`
   - Mac opens file if `openOnMac: true`
   - Mac shows notification: "File received from Android"

### Mac unavailable — clean failure

1. Stop JarvisMac (or disconnect from daemon).
2. Say "open safari on the mac" to Android.
3. Expected:
   - Daemon detects no Mac client connected
   - Returns `mac_client_unavailable` nack immediately
   - Android TTS speaks "The Mac is not connected."
   - No request left pending; no timeout wait

### File transfer with Mac reconnect

1. Upload a file from Android while Mac is disconnected.
2. Reconnect Mac to daemon.
3. Expected:
   - `file.transfer.created` event is in offline queue (replay-safe type)
   - Daemon drains queue to Mac on reconnect
   - Mac downloads and saves file
   - File arrives in `~/Downloads/Jarvis Transfers/`

---

## Soak / Stress Test Checklist

### Daemon stability (run for 30 min continuous)
- [ ] No memory growth in daemon process (check with `ps aux` before/after)
- [ ] `DaemonTimeline` stays at ≤ 500 events
- [ ] `PresenceStore` stays at ≤ 50 entries
- [ ] `DaemonOfflineQueue` stays at ≤ 50 messages
- [ ] Ping loop does not accumulate after rapid reconnects (check for `asyncAfter` orphans via log rate)
- [ ] Proactive ticker fires ~once/minute (check `ProactiveCoordinator` log)

### Android reconnect stress
- [ ] Force-close and reopen Android Jarvis 10 times — only 1 heartbeat loop active after each reconnect
- [ ] Toggle airplane mode 5 times while connected — NetworkChangeObserver triggers reconnect each time
- [ ] Verify `sharedStatus` transitions: Disconnected → Connecting → Connected → Reconnecting → Connected

### Cross-device latency targets
- [ ] `daemon_rtt` < 50ms on LAN
- [ ] `transcript_sent` → `android_reply_received` < 3000ms for LLM path
- [ ] `transcript_sent` → `android_reply_received` < 500ms for fast-route path

### Handoff
- [ ] "Continue this on the Mac" → text appears in Mac overlay within 2s
- [ ] "Open this on the Mac" with a URL → browser opens on Mac within 2s
- [ ] Old handoffs (>24h) do not appear in `GET /v1/handoffs`
- [ ] Handoff with >200 char text → stored summary truncated to 200 chars

### Security invariants
- [ ] Send a comm.event.received with raw phone number → verify daemon log shows ****last4 only
- [ ] Attempt to handoff a .dmg URL → verify blocked
- [ ] comm.action.execute frame — verify requiresConfirmation=true in all code paths
