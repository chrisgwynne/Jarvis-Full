# Windows Desktop Tools — Phase 4

## Overview

The tool layer exposes a set of named, safety-gated, alias-resolved Windows desktop actions
that the Mac brain can invoke over the bridge, or that dashboard quick actions can trigger locally.

## Tool Inventory

| Name | Aliases | Safety Level | Privacy Impact | Settings gate |
|---|---|---|---|---|
| `open_app` | open, launch, start_app | Confirm | None | `Tools.Enabled` |
| `focus_app` | focus, bring_to_front, switch_to | Safe | None | `Tools.Enabled` |
| `close_app` | close, quit_app | Confirm | None | `Tools.AllowAppClose` |
| `screenshot_window` | screenshot, capture_screen, capture_window | Confirm | Screenshot | `Tools.AllowScreenshots` |
| `clipboard_summary` | clipboard, what_is_in_clipboard | Safe | Clipboard | `Tools.AllowClipboardRead` (default false) |
| `volume_control` | volume, mute, unmute, set_volume | Safe | None | `Tools.Enabled` |
| `inspect_processes` | processes, what_is_running, running_apps | Safe | AppList | `Tools.Enabled` |
| `open_project` | project, open_repo, open_folder | Confirm | FilePath | `Tools.Enabled` |

## Safety Levels

| Level | Behaviour |
|---|---|
| `Safe` | Executes immediately; read-only or trivially reversible |
| `Confirm` | Reversible; execution proceeds (no interactive prompt at tool layer) |
| `Approve` | Significant effect; currently unused at tool layer (handled by AutomationExecutor for low-level intents) |
| `Blocked` | Policy prevents execution; returns failure result with reason |

## Invoking from the Mac Bridge

Send a `windows.tool.request` frame:
```json
{
  "type": "windows.tool.request",
  "id": "<routeId>",
  "toolName": "open_app",
  "toolParameters": { "app": "vscode" },
  "dryRun": false,
  "at": "2025-05-25T12:00:00Z"
}
```

Windows responds with `windows.tool.result`:
```json
{
  "type": "windows.tool.result",
  "id": "<routeId>",
  "toolSuccess": true,
  "toolSummary": "Opened vscode",
  "toolDetail": "Launched 'code.exe'",
  "privacyImpact": "None",
  "at": "2025-05-25T12:00:01Z"
}
```

## App Alias Table (open_app / focus_app)

| Alias | Resolves to |
|---|---|
| chrome | chrome.exe |
| edge | msedge.exe |
| firefox | firefox.exe |
| vscode, code | code.exe |
| cursor | cursor.exe |
| visual studio | devenv.exe |
| spotify | Spotify.exe |
| steam | steam.exe |
| discord | Discord.exe |
| teams | Teams.exe |
| outlook | OUTLOOK.EXE |
| notepad | notepad.exe |
| calculator | calc.exe |
| settings | ms-settings: (shell URI) |
| explorer | explorer.exe |
| paint | mspaint.exe |
| terminal | wt.exe |
| powershell | pwsh.exe |

## Required Settings

```json
{
  "Tools": {
    "Enabled": true,
    "AllowScreenshots": true,
    "AllowClipboardRead": false,
    "AllowAppClose": true,
    "AllowForceClose": false
  },
  "Projects": {
    "Aliases": [
      { "Alias": "jarvis", "Path": "C:\\Users\\you\\Jarvis-Full", "App": "vscode" }
    ]
  }
}
```

## Example Mac→Windows Tool Calls

```
"open chrome"           → open_app { app: "chrome" }
"focus visual studio"   → focus_app { app: "visual studio" }
"close discord"         → close_app { app: "discord" }
"take a screenshot"     → screenshot_window {}
"what is in clipboard"  → clipboard_summary {}
"mute"                  → volume_control { action: "mute" }
"what is running"       → inspect_processes {}
"open jarvis project"   → open_project { project: "jarvis" }
```
