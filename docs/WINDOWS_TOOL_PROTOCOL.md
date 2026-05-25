# Windows Tool Bridge Protocol

## Frame Types

### `windows.tool.request` (Mac → Windows)

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | yes | `"windows.tool.request"` |
| `id` | string | yes | RouteId for correlation — echoed back in result |
| `toolName` | string | yes | Canonical name or alias (case-insensitive) |
| `toolParameters` | object | no | Key-value string map of parameters |
| `dryRun` | bool | no | If true, validate but do not execute |
| `at` | ISO8601 | yes | Request timestamp; used for stale-request guard |

### `windows.tool.result` (Windows → Mac)

| Field | Type | Always present | Description |
|---|---|---|---|
| `type` | string | yes | `"windows.tool.result"` |
| `id` | string | yes | Echoes the request's `id` for correlation |
| `toolSuccess` | bool | yes | Whether execution succeeded |
| `toolSummary` | string | yes | Short user-facing summary |
| `toolDetail` | string | no | Technical detail for diagnostics (no sensitive data) |
| `artifactPath` | string | no | Local file path for artifacts (e.g. screenshot PNG) |
| `privacyImpact` | string | yes | `None` / `AppList` / `Clipboard` / `Screenshot` / `FilePath` |
| `at` | ISO8601 | yes | Response timestamp |

## RouteId Correlation

The Mac sends a `id` (routeId) on each request. Windows echoes it back unchanged in the result `id` field. The Mac uses this to match results to outstanding requests. If no `id` is provided by the Mac, Windows generates a UUID and uses that.

## Timeout Behaviour

Each tool execution has a **30-second timeout** (configured in `WindowsToolBridge`). If a tool does not complete within 30 seconds:

- Windows sends a failure result with summary `"Tool '{name}' timed out after 30 seconds."`
- The Mac's result handler sees `toolSuccess: false`

## Stale Request Handling

Requests with `at` older than **60 seconds** are silently dropped — no result is sent back. This prevents queued requests from replaying on reconnect if they are no longer relevant.

Stale drop is logged at `Warn` level in diagnostics with fields `tool` and `age_ms`.

## Safety Levels

Tools declare their `ToolSafetyLevel`. The bridge does not enforce modal approval (that is the `IApprovalPolicy` domain for low-level `AutomationIntent`). For tool-layer safety:

- `Safe` — executes immediately
- `Confirm` — executes (brief action; the Mac UI informs the user)
- `Blocked` — returns a failure result with a policy reason; never executes

Settings-based blocks (`AllowAppClose = false`, `AllowForceClose = false`, etc.) always return `toolSuccess: false` with a clear message.

## Tool Registry

The registry is immutable after construction. Tools are registered as `IWindowsTool` singletons in DI and injected into `WindowsToolRegistry`. Lookup is case-insensitive on canonical name and all aliases.

When `ToolsSettings.Enabled = false`, `IWindowsToolRegistry.Find()` always returns null — every request results in a failure result.

## Example Exchange

**Request (Mac → Windows):**
```json
{
  "type": "windows.tool.request",
  "id": "req-abc123",
  "toolName": "open_app",
  "toolParameters": { "app": "chrome" },
  "dryRun": false,
  "at": "2025-05-25T14:30:00.000Z"
}
```

**Result (Windows → Mac):**
```json
{
  "type": "windows.tool.result",
  "id": "req-abc123",
  "toolSuccess": true,
  "toolSummary": "Opened chrome",
  "toolDetail": "Launched 'chrome.exe'",
  "privacyImpact": "None",
  "at": "2025-05-25T14:30:00.250Z"
}
```
