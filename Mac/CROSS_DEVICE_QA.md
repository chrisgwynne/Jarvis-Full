# Cross-Device QA Checklist

## Android Pairing

1. Open JarvisMac → Gateway Settings → Daemon tab
2. Verify daemon shows "Running" status
3. Click "Generate Pairing Code" — a 6-digit code appears
4. On Android: enter the code to pair
5. Verify device appears in Paired Devices list
6. Verify voice commands route Mac→Android correctly

## Windows Sidecar Pairing

1. Open JarvisMac → Gateway Settings → Daemon tab
2. Generate a pairing code
3. On Windows: enter `jarvis-pair://<code>` or use the Windows Jarvis app
4. Verify device appears as "Windows" platform in Paired Devices list
5. Verify Windows presence updates appear in the Message Router section

## Daemon-Unavailable Testing

1. Kill the daemon: `launchctl stop com.jarvis.brain`
2. Launch JarvisMac — should show orange banner in Gateway Settings → Daemon tab
3. Banner text: "Jarvis daemon unavailable — Jarvis is running in limited local mode until the daemon reconnects."
4. Voice commands still work (local only)
5. Start daemon: `launchctl start com.jarvis.brain`
6. Banner should auto-dismiss within the health check interval (≤30s)

## Offline Queue Testing

1. Connect an Android device to the daemon
2. Kill the Mac app (or simulate Mac disconnect from daemon perspective)
3. From Android, send several voice commands (transcript.final messages)
4. Reconnect the Mac app
5. Verify queued messages are delivered in FIFO order
6. Check Router Status section in Daemon tab: "Offline queue depth" should return to 0

## Port Conflict Detection

1. Run `nc -l 8765` to bind port 8765 externally
2. Open Gateway Settings → Daemon tab
3. Verify "Port status" shows a conflict warning (red text)
4. Kill `nc`, verify port status clears on next poll (≤30s)

## Token Security Verification

1. Pair a device
2. Check `~/Library/Application Support/JarvisMac/gateway_paired_devices.json`
3. Verify only `tokenHash` (SHA-256) is present — no raw token values
4. Check daemon logs: `log show --predicate 'subsystem == "com.jarvis.daemon"' --last 5m`
5. Verify no token or bearer values appear in log output

## Revoke Device

1. Open Gateway Settings → Daemon tab → Paired Devices
2. Click "Revoke" on a device
3. Verify the revoked device cannot send further messages (daemon returns 401)
4. Verify device moves to "Revoked" disclosure group in UI
