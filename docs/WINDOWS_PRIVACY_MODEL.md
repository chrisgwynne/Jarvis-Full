# Windows Privacy Model

## What is collected

Jarvis Windows collects only the minimum information needed for context-aware assistance:

- **Process names**: the executable name of the foreground application (e.g. `Code`, `chrome`)
- **Workflow categories**: coarse classification (Coding, Browsing, Communication, etc.) — never fine-grained content
- **Dwell times**: how long a process was in the foreground (in seconds/minutes)
- **Focus metrics**: session start time, focus duration, app switch count, distraction count, productivity score
- **Presence mode**: Work / Focus / Casual / Gaming / Presentation / Silent / Developer

## What is NEVER stored

The following are explicitly dropped or never captured:

- **Raw window titles** when they match a sensitive pattern (see filter below)
- **URLs** from private/incognito browsing sessions
- **Conversation transcripts** or speech audio
- **Clipboard content** beyond a configurable character limit (`MaxClipboardChars`, default 500 chars)
- **Selected text** beyond a configurable character limit (`MaxSelectedTextChars`, default 2,000 chars)
- **Passwords** or credentials
- **Financial information** (banking, payment details)
- **Personal health information**
- **API keys or session tokens** in cleartext

## Sensitive title filter

Window titles matching any of the following patterns (case-insensitive) cause `TitleRedacted = true` in the `AppUsageEntry`. Only the process name and workflow category are retained:

```
incognito
private browsing
 - inprivate
password
bank
paypal
1password
bitwarden
keepass
```

The `TitleRedacted` flag is visible in diagnostics and the Context Inspector but the original title value is never stored anywhere.

## Data retention

### In-memory ring buffer
`AppUsageTracker` keeps at most `AwarenessSettings.AppUsageHistoryDepth` (default 20) entries in memory. Older entries are automatically overwritten.

### Timeline payload to Mac
`PrivacySafeTimeline` includes at most `ContextEngineSettings.TimelineSummaryDepth` (default 10) entries. Each entry contains only `ProcessName`, `WorkflowCategory`, `Dwell`, and `StartedAt` — no titles or URLs.

### Session history file
`SessionMemoryStore` appends one JSON line per `WorkSession` to `%APPDATA%\Jarvis\sessions.jsonl`. The file is capped at **512 KB**; when exceeded on write, the oldest 20% of lines are trimmed automatically. `WorkSession` records contain no titles, URLs, or sensitive content — only process names, workflow categories, and aggregated metrics.

## User controls

| Control | Location | Effect |
|---|---|---|
| Privacy Mode | Settings → Sidecar | Suppresses mic input and context push to Mac |
| Clear history | SessionMemoryStore.ClearAsync() | Deletes sessions.jsonl |
| Distraction alerts | Settings → Proactivity | Disable distraction nudges |
| Context injection | Settings → LLM | Remove context block from LLM prompts |
| Max clipboard chars | Settings → Redaction | Cap clipboard content size |
| Max selected text chars | Settings → Redaction | Cap selected text size |

## DPAPI usage

API keys and session tokens are encrypted at rest using Windows DPAPI (Data Protection API) via `System.Security.Cryptography.ProtectedData`:

- **LLM API keys** (`LlmSettings.ApiKey`) are encrypted on save, decrypted on load by `JsonSettingsStore`
- **Bridge session tokens** (`BrainGatewayConfig.SessionToken`) are DPAPI-protected; only the current Windows user account can decrypt them
- Raw token values are never logged; diagnostics show only the first 4 characters followed by `…`

## Network privacy

- Context payloads are sent **only when the Mac bridge is connected** and the snapshot hash has changed
- Privacy Mode (`SidecarSettings.PrivacyMode = true`) suspends all context push and mic capture
- The bridge uses TLS (wss://) when `BaseUrl` uses https; plain ws:// is available for local LAN use
