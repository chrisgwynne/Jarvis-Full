# Cross-Device QA Script

Manual QA checklist for the Mac Brain ↔ Android/Windows sidecar path.
Run against a real device before merging any cross-platform protocol change.

---

## Prerequisites

| Item | Expected |
|------|----------|
| JarvisMac running on Mac | port 8765 listening |
| Android device on same network/Tailscale | Jarvis app installed |
| Windows PC (optional) | Jarvis Windows app installed |

---

## 1 — Pairing

### 1a Android pairing

1. Open Android → Settings → Mac Integration.
2. Enter Mac's IP/hostname in the Gateway URL field (e.g. `http://192.168.1.5:8765`).
3. On Mac: open Brain API settings → tap "Generate Pairing Code". Note the 6-digit code.
4. Enter the 6-digit code in Android's Pairing Code field. Tap Pair.
5. **Expected:** status changes to "Paired" within 3 seconds. No 400 error in logs.
6. Confirm `gateway_paired_devices.json` on Mac contains the new device entry.

### 1b Windows pairing

1. Open Windows Jarvis Settings → Mac Integration.
2. Enter Mac Gateway URL.
3. Request pairing code on Mac, enter in Windows Settings.
4. **Expected:** status shows "Connected" in the Windows tray.

---

## 2 — Android STT → Mac Brain → Android TTS

1. Ensure Android is paired and status shows Connected.
2. Say the wake word on Android.
3. Ask: "What time is it?" (a simple factual query).
4. **Expected:**
   - Android shows "Listening" state.
   - `[TRANSCRIPT_RAW]` logged in Android logcat.
   - `sendTranscript` log appears: `"sendTranscript: what time is it"`.
   - Mac logs `onTranscriptFinal` received, routes through brain pipeline.
   - Mac sends `reply.final` frame back.
   - Android `onReplyFinal` fires → `speakAndRecord` called.
   - Android TTS speaks the reply.
5. **Negative check:** if gateway is Disconnected, transcript is NOT sent — Android handles locally.

---

## 3 — Windows STT → Mac Brain → Windows TTS

1. Ensure Windows is connected to Mac Gateway.
2. Trigger a voice command on Windows ("What's on my calendar?").
3. **Expected:**
   - Windows sends `transcript.final` via `/v2/ws`.
   - Mac's `MacBridgeProtocolV2.onInboundTranscript` fires.
   - `handleRemoteTranscript` runs through Mac brain pipeline.
   - `v2.pushReplyFinal(text:)` sends `reply.final` back.
   - Windows TTS speaks the reply.

---

## 4 — Mac proactive push → Android

1. On Mac, trigger a proactive event (e.g. a timer expiry or calendar alert).
2. **Expected:** Android receives `proactive.notify` frame, `onProactiveNotify` fires, notification or TTS plays on Android.

---

## 5 — Mac orchestrate.speak → Android

1. On Mac, issue a voice command that results in an `orchestrate.speak` push.
2. **Expected:** Android speaks the text via `speakAndRecord` (follows driving mode, barge-in, and conversation memory paths).

---

## 6 — Disconnect / reconnect

1. Kill network or move Android out of range.
2. **Expected:** status transitions to Reconnecting, then back to Connected when network restores.
3. Send a transcript while disconnected — verify it is handled locally (no crash, no silent drop).

---

## 7 — Re-pair flow

1. On Mac, revoke the Android device token.
2. On Android, try to send a transcript.
3. **Expected:** gateway receives 401 → status transitions to Unauthorized → Android surfaces re-pair prompt.

---

## 8 — Pairing code expiry

1. Generate a 6-digit pairing code on Mac.
2. Wait 10 minutes without using it.
3. Try to pair with the stale code.
4. **Expected:** pairing returns error; new code required.

---

## Log grep targets

| Event | Platform | Tag / message |
|-------|----------|---------------|
| STT complete | Android | `[TRANSCRIPT_RAW]` |
| Transcript sent to Mac | Android | `sendTranscript:` |
| Transcript received on Mac (Android) | Mac | `onTranscriptFinal` |
| Transcript received on Mac (Windows) | Mac | `onInboundTranscript` |
| Reply sent to Android | Mac | `reply.final` |
| Reply received on Android | Android | `onReplyFinal` |
| TTS started | Android | `[AUDIO_FOCUS_REQUEST]` |
| Pairing success | Mac | `completePairing` |
| Gateway connected | Android | `Connected to Mac Brain Gateway` |
| Auth file collision check | Mac | verify only one process writes `gateway_paired_devices.json` |
