# Jarvis Context Bridge — Chrome / Edge extension

Streams the active tab's context to the local Jarvis runtime over an **authenticated**
loopback WebSocket (`ws://127.0.0.1:49321/?token=…`) and receives host commands.

## Load unpacked

1. Make sure Jarvis is running.
2. Open `chrome://extensions/` (or `edge://extensions/`).
3. Toggle **Developer mode** on (top right).
4. Click **Load unpacked** and pick this folder.
5. **Paste the bridge token:**
   - In Jarvis's tray menu, click **Copy bridge token**.
   - In `chrome://extensions`, click **Details** on the Jarvis Context Bridge entry.
   - Click **Extension options**.
   - Paste the token and click **Save and reconnect**.
6. Open any tab — the Context Inspector in Jarvis should show the URL within ~1 s.

## Wire protocol (v2)

Direction is bidirectional. Every host command carries a `commandId`; the extension
replies with exactly one ack frame containing the same id.

```jsonc
// extension → host
{ "type": "hello", "browser": "chrome", "version": "0.2.0" }
{ "type": "context", "browser": "chrome", "url": "…", "domain": "…", "title": "…",
  "selectedText": "…", "focusedElementRole": "textbox", "isTextInputFocused": true }
{ "type": "ping" }
{ "type": "ack", "commandId": "abc", "accepted": true, "completed": true,
  "resultingUrl": "…", "resultingTitle": "…", "matches": 1, "sample": "button#submit Buy" }

// host → extension
{ "type": "navigate", "commandId": "abc", "url": "https://example.com/" }
{ "type": "reload",   "commandId": "abc" }
{ "type": "back" | "forward", "commandId": "abc" }
{ "type": "scroll",   "commandId": "abc", "dy": 400 }
{ "type": "focusInput","commandId": "abc", "selector": "input[name=q]" }
{ "type": "extractSelection", "commandId": "abc" }
{ "type": "dryRun",   "commandId": "abc", "selector": "button#submit" }
{ "type": "click",    "commandId": "abc", "selector": "button#submit" }
```

Unknown fields are ignored. The host considers a command **completed** only when the
ack arrives with `completed: true`. Timeouts and disconnects synthesise a non-completed
ack on the host side; the executor reports them as `Failed`.

## Selector clicks are dry-run-then-go

`click` is a **two-phase** operation: the host first sends `dryRun` for the selector
and only proceeds when the ack reports `matches === 1`. Selectors that match 0 or
many elements are refused with a structured error before any DOM mutation.

## Security model (P3.5)

- **Token-authenticated.** Server reads `?token=` from the WebSocket URL, compares
  constant-time against the on-disk shared secret at
  `%APPDATA%\Jarvis\bridge-token.txt`. Mismatch → 401, audit log records the rejection.
- Bind is still loopback-only.
- Anyone with file-system access to `%APPDATA%\Jarvis\` can read the token. We treat
  the per-user file system as a trust boundary — same as SSH keys.
- The extension does **not** request `<all_urls>` host permissions; DOM access is
  scoped via `activeTab` + `scripting` and only after a tab activation.

## Reconnect

- 500 ms initial backoff, doubling to a 15 s cap.
- Saving a new token in options closes the current socket so reconnect picks it up.
- A fresh `hello` supersedes any previous extension instance on the host side.
