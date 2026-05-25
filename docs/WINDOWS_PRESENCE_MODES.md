# Windows Presence Modes

## Overview

`PresenceMode` determines how proactively Jarvis behaves on Windows. It can be auto-detected from context signals or manually overridden by the user.

## All 7 Modes

| Mode | Description | Auto-detected when |
|---|---|---|
| `Work` | Normal desk work, standard proactivity | Default; no specific signals |
| `Focus` | Deep work detected, reduced proactivity | `FocusState` is `Focused` or `DeepWork` |
| `Casual` | Browsing/media, relaxed mode | Primary workflow is Media, Browsing, or Shopping |
| `Gaming` | Gaming app in foreground, suppress all proactive speech | Any recent process matches gaming set |
| `Presentation` | Fullscreen sustained session | Primary workflow Unknown + AppSwitches <= 1 + FocusDuration >= 5 min |
| `Silent` | User-set override, zero proactivity | `SetMode(PresenceMode.Silent)` |
| `Developer` | Debug/dev mode, verbose diagnostics | `AwarenessSettings.DevMode == true` |

## Auto-detection Logic

Detection is priority-ordered (highest wins):

1. **Gaming**: any entry in the recent app usage window has a process name in the gaming set:
   `steam`, `EpicGamesLauncher`, `gameoverlayui`, `RiotClientServices`, `LeagueClient`, `Minecraft.Windows`, `javaw`, `destiny2`, `Warzone`, `csgo`, `dota2`, `valorant`, `RocketLeague`, `overwatch`, `fortnite`

2. **Presentation**: `PrimaryWorkflow == Unknown && AppSwitchesLast10Min <= 1 && FocusDuration >= 5 min`
   (heuristic for fullscreen apps like PowerPoint or slideshow tools)

3. **Developer**: `AwarenessSettings.DevMode == true`

4. **Focus**: `FocusState` is `DeepWork` or `Focused`

5. **Casual**: `PrimaryWorkflow` is `Media`, `Browsing`, or `Shopping`

6. **Work**: default fallback

## User Override

```csharp
// Set a manual override
presenceManager.SetMode(PresenceMode.Silent);
presenceManager.IsUserOverride == true   // auto-detection suspended

// Return to auto-detection
presenceManager.ClearOverride();
presenceManager.IsUserOverride == false  // re-inference fires immediately
```

When `IsUserOverride == true`, all auto-detection events (from `EntryAdded` and `MetricsChanged`) are suppressed.

## Per-mode Behavior Matrix

| Mode | Proactivity | Nudge suppression | Diagnostics | Bridge routing |
|---|---|---|---|---|
| Work | Standard | None | Normal | Full |
| Focus | Reduced | `distraction_loop` (when SuppressDuringFocus) | Normal | Full |
| Casual | Relaxed | None | Normal | Full |
| Gaming | Minimal | All nudges | Normal | Full |
| Presentation | Minimal | All nudges | Normal | Full |
| Silent | Zero | All nudges | Normal | Full |
| Developer | Standard | None | Verbose | Full |

## How the Mac Brain Queries the Mode

The current `PresenceMode` is included in every `ContextPayload` frame as the `presenceMode` string field:

```json
{
  "type": "context",
  "context": {
    "presenceMode": "Focus",
    "focusMinutes": 47.0,
    "productivityScore": 0.73,
    "appSwitchesLast10Min": 3
  }
}
```

The Mac brain can use `presenceMode` to:
- Decide whether to initiate proactive speech
- Adjust response verbosity
- Route requests to different personas or tools
