# Jarvis Windows — User Guide

## What is Jarvis Windows?

Jarvis Windows is the desktop sidecar that pairs with your Mac Jarvis brain. It runs silently
in the system tray and:

- Sends real-time context to the Mac (what you're working on, focus state, presence mode)
- Executes desktop actions the Mac brain requests (open apps, focus windows, take screenshots)
- Provides the Mac with memory queries about your session history
- Shows a dashboard with your focus session, workflow, and productivity metrics
- Plays back Mac responses through Windows TTS (when enabled)

## How It Works with the Mac Brain

```
  Mac Jarvis Brain
      │
      │ WebSocket (TLS)
      │
  Windows Sidecar
  ├── Context push (process name, workflow, focus state)
  ├── Tool execution (open_app, screenshot, etc.)
  └── Memory queries (coding time, distractions, focus duration)
```

The Mac is authoritative for:
- Conversation and LLM responses
- TTS lease authority
- Proactive suggestions

Windows handles:
- Desktop context collection
- Tool execution
- Session memory storage
- Local wake word detection

## What Context is Collected

| Data | Purpose | Where it goes |
|---|---|---|
| Foreground process name | Workflow classification | Mac context payload |
| Workflow category (e.g. Coding, Browsing) | Session tracking | Mac + local JSONL |
| Focus duration | Productivity metrics | Local only |
| App switch count | Distraction detection | Local only |
| Presence mode | Proactive suppression | Mac context payload |
| Productivity score | Dashboard / Mac context | Mac context payload |

## What is NEVER Collected

- Window titles (filtered for privacy-sensitive patterns)
- URLs from private/incognito browsing
- Clipboard content (unless you explicitly enable it in Settings → Tools)
- Conversation transcripts or speech audio
- Passwords, credentials, or financial information
- File contents

## How to Disable Context Collection

| Action | How |
|---|---|
| Stop all context push | Settings → Sidecar → Privacy Mode = on |
| Disable clipboard reading | Settings → Tools → AllowClipboardRead = false (default) |
| Disable screenshots | Settings → Tools → AllowScreenshots = false |
| Disable tools entirely | Settings → Tools → Enabled = false |

## Available Commands

Speak or type to Jarvis on Mac. These are processed Mac-side and may trigger a tool on Windows.

### App control
- "Open Chrome" / "Launch VS Code"
- "Focus Discord" / "Bring Spotify to front"
- "Close Notepad"

### Screen
- "Take a screenshot"

### System
- "Mute" / "Unmute" / "Set volume to 50"
- "What is running?" / "Show running apps"

### Projects
- "Open the Jarvis project"  (requires projects.json or Settings.Projects.Aliases)

### Memory queries
- "How long did I code today?"
- "What distracted me?"
- "What was I doing before lunch?"
- "Summarise my afternoon"
- "What apps did I use most?"
- "How long was I focused?"
- "What is my productivity score?"

## Dashboard

Open from the system tray → Dashboard or press Ctrl+Shift+D.

**Cards:**
1. **Jarvis Status** — presence mode, Mac connection status
2. **Focus Session** — current focus duration, state, productivity bar
3. **Activity** — current workflow, app switches, smart suggestion
4. **Today** — timeline summary of today's sessions
5. **Device Health** — Mac connection status
6. **Quick Actions** — Focus Mode toggle, Screenshot, Running Apps
7. **Recent Actions** — last 5 tool runs (name, result, time)

### Quick Actions

| Button | Effect |
|---|---|
| Focus Mode | Toggles Focus presence mode on/off |
| Screenshot | Captures current foreground window to %APPDATA%\Jarvis\Screenshots\ |
| Running Apps | Lists top processes by memory in a popup |

## Example Conversations

> "Open Visual Studio Code"
→ Launches VS Code via the open_app tool

> "What have I been working on today?"
→ Mac queries Windows memory and summarises your session history

> "Take a screenshot and show me what's on screen"
→ screenshot_window captures the current window; path returned to Mac

> "Mute my speakers"
→ volume_control toggles mute via WM_APPCOMMAND

> "Focus Spotify"
→ focus_app brings Spotify to the foreground if running

> "Open my Jarvis project"
→ open_project opens the configured folder path in Explorer or an IDE
