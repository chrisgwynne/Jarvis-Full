# Jarvis macOS — Feature Tracker

> Last updated: 2026-05-18  
> Build: Sprint D complete — A1 HA WebSocket Proactivity, A3 Shopify, A4 Home Overlay, A8 Timers, A9 Clipboard, A10 Spotify, A14 Conversation Summaries, A15 Semantic Memory

---

## How to use this file

- ✅ **Implemented** — fully working, committed, compiles
- ⚠️ **Partial** — code exists but has known gaps or requires manual setup
- 🔲 **Planned** — not yet built
- ❌ **Won't build** — intentionally out of scope

Each feature lists **voice triggers**, **what it does**, and **dependencies** required to function.

---

## Table of Contents

1. [News](#1-news)
2. [Camera & Vision](#2-camera--vision)
3. [Screen Awareness](#3-screen-awareness)
4. [Smart Home (Home Assistant)](#4-smart-home-home-assistant)
5. [Calendar](#5-calendar)
6. [Todoist Tasks](#6-todoist-tasks)
7. [Weather](#7-weather)
8. [macOS System Control](#8-macos-system-control)
9. [Overlays & UI](#9-overlays--ui)
10. [Proactivity & Notifications](#10-proactivity--notifications)
11. [Memory](#11-memory)
12. [Identity & Personal Facts](#12-identity--personal-facts)
13. [Operating Modes](#13-operating-modes)
14. [Listening Lifecycle](#14-listening-lifecycle)
15. [Daily Briefing](#15-daily-briefing)
16. [Small Talk & Status](#16-small-talk--status)
17. [GitHub (Proactive)](#17-github-proactive)
18. [Android / WebSocket Bridge](#18-android--websocket-bridge)
19. [Timers & Stopwatch](#19-timers--stopwatch)
20. [Clipboard Integration](#20-clipboard-integration)
21. [Spotify Music Control](#21-spotify-music-control)
22. [Shopify Integration](#22-shopify-integration)
23. [Home Assistant Overlay](#23-home-assistant-overlay)
24. [Planned Features](#24-planned-features)

---

## 1. News

**Dependencies:** RSS feeds configured in `NewsSourceRegistry`. LLM optional for summaries.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show News | "show news", "news", "latest news", "headlines", "what's in the news", "what's happening" | Opens the news/RSS overlay |
| ✅ | Close News | "close news", "hide news", "dismiss news" | Closes news overlay |
| ✅ | Watch Live News | "watch news", "play the news", "live news", "watch live news" | Opens news overlay with live video channel active |
| ✅ | Summarise News | "summarise the news", "read headlines", "news summary", "brief me on the news" | Speaks top headlines via TTS |
| ✅ | Refresh News | "refresh news", "update news", "reload news" | Refetches all RSS feeds |
| ✅ | Next Channel | "next news channel", "next channel", "change channel" | Cycles to next live news channel |
| ✅ | Previous Channel | "previous channel", "last channel" | Cycles to previous channel |
| ✅ | Watch Named Channel | "watch Bloomberg", "switch to BBC News", "watch Sky News" | Switches live feed to named channel |
| ✅ | Open Story N | "open story one", "open the first story", "open article 2" | Opens nth article from news list |
| ✅ | Summarise Story N | "summarise story two", "summarize article 3" | Speaks summary of nth article |
| ✅ | Save Article | "save this article", "bookmark this" | Bookmarks current article |
| ✅ | Show Saved Articles | "saved news", "saved articles", "show bookmarks" | Shows bookmarked articles |
| ✅ | Open In Browser | "open in browser", "open in safari" | Opens focused article in Safari |
| ✅ | Close Article | "close article", "close web", "close page" | Closes article web-view overlay |
| ✅ | Search News | "find news about X", "search news for X" | Filters news by query |
| ✅ | News By Label | "tech news", "AI news", "business news", "world news", "UK news" | Filters news overlay to a label category |
| ✅ | Open That Story | "open that story", "open that article", "open that" | Opens overlay for last-announced story |
| ✅ | Summarise That | "summarise that", "tell me more about that", "give me the details" | Speaks summary of last proactive news signal |

---

## 2. Camera & Vision

**Dependencies:** Camera permission, webcam attached. LLM vision (MiniMax) optional for richer descriptions.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show Camera | "show camera", "camera", "open my camera" | Opens live webcam overlay (cinema size) |
| ✅ | Close Camera | "close camera", "hide camera", "dismiss camera" | Closes camera overlay |
| ✅ | Describe View | "what can you see", "what do you see", "describe the view", "look around", "describe what you see" | Captures frame and describes it via Apple Vision or LLM |
| ✅ | Take Photo | "take a photo", "take a picture", "snap a photo", "capture image" | Captures still image from webcam |
| ✅ | Is Anyone There | "is anyone there", "anyone home", "who is there", "am I visible" | Checks camera frame for human presence |
| ✅ | Watch the Desk | "watch the desk", "monitor my desk" | Starts periodic desk monitoring |
| ✅ | Watch Room | "watch the room", "monitor the room" | Starts periodic room monitoring |
| ✅ | Stop Watching Camera | "stop watching camera", "stop camera watch" | Stops camera monitoring |
| ✅ | Read This (camera OCR) | "read this", "read" | OCR on camera view |
| ✅ | Scan This | "scan this", "scan the document" | Scan and interpret visual content |
| ✅ | Show HA Camera | "show front door camera", "show doorbell camera", "show backyard" | Shows Home Assistant camera entity snapshot in overlay |

---

## 3. Screen Awareness

**Dependencies:** Screen Recording permission in System Settings > Privacy.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | What Am I Looking At | "what am I looking at", "what's on my screen", "describe my screen" | Captures screen and describes content |
| ✅ | Read My Screen | "read my screen", "read the screen", "read screen" | OCR on current screen |
| ✅ | Summarise Screen | "summarise this screen", "screen summary" | Brief spoken summary of screen content |
| ✅ | Take Screenshot | "screenshot", "take a screenshot", "capture screen" | Takes screenshot |
| ✅ | Watch My Screen | "watch my screen", "monitor my screen" | Starts periodic screen monitoring loop |
| ✅ | Stop Watching Screen | "stop watching screen", "stop screen watch" | Cancels screen watch |
| ✅ | What App Am I Using | "what app am I using", "what am I using" | Identifies frontmost application |
| ✅ | Show Screen Overlay | "show screen overlay", "screen awareness" | Opens screen overlay panel |
| ✅ | What Text Do You See | "what text", "what does the screen say", "read the text" | OCR read of visible text |

---

## 4. Smart Home (Home Assistant)

**Dependencies:** Home Assistant running on local network. Requires `Base URL` + `Long-lived access token` in Settings → Home.  
**Tip:** Add entity aliases in Settings → Home → Entity Aliases to map spoken names (e.g. "desk lamp") to HA entity IDs.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Home Status | "home status", "smart home status", "show home" | Fetches and speaks all entity states |
| ✅ | Turn On Device | "turn on [entity]", "switch on [entity]", "light on" | Turns on lights, switches, etc. |
| ✅ | Turn Off Device | "turn off [entity]", "switch off [entity]", "shut off" | Turns off entity |
| ✅ | Set Brightness | "dim [entity] to 40", "brighten bedroom", "set brightness to 70 percent" | Sets light brightness |
| ✅ | Set Color | "make the bedroom lamp red", "set desk lamp to blue", "change light to warm white" | Sets light color |
| ✅ | Activate Scene | "activate scene dinner", "scene movie", "set scene reading" | Triggers a HA scene |
| ✅ | Open Cover | "open the garage", "open the blinds", "open the curtains" | Opens a cover/blind/garage |
| ✅ | Close Cover | "close the garage", "close the blinds" | Closes a cover entity |
| ✅ | Lock Door | "lock the door", "lock front door", "lock [entity]" | Locks a lock entity (safety: medium) |
| ✅ | Unlock Door | "unlock the door", "unlock front door" | Unlocks a lock entity (safety: medium) |
| ✅ | Entity Status | "status of [entity]", "is the [entity] on" | Reads a single entity's state |
| ✅ | Show HA Camera | "show front door camera", "show [camera name]" | Shows HA camera snapshot in overlay |
| ✅ | Entity Aliases | *Configured in Settings* | Map spoken names to HA entity IDs for reliable resolution |

---

## 5. Calendar

**Dependencies:** EventKit calendar + reminders permissions (macOS will prompt on first use). Syncs with any calendar configured in macOS Calendar.app (Google, iCloud, Exchange, etc.).

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show Calendar | "show calendar", "calendar", "today's events", "what are my events", "what's on my calendar" | Opens calendar overlay with today's event timeline |
| ✅ | Next Meeting | "next meeting", "when is my next meeting", "next appointment" | Speaks time and title of next event |
| ✅ | Meetings Today | "meetings today", "what do I have today", "schedule today" | Lists all today's events |
| ✅ | Add Reminder | "remind me to [X]", "remind me about [X]", "set a reminder to [X]" | Creates reminder in macOS Reminders |
| ✅ | **Proactive: 10-min warning** | *automatic* | "Heads up — [meeting] starts in about 10 minutes" |
| ✅ | **Proactive: 1-min warning** | *automatic* | "[Meeting] is starting now" |

---

## 6. Todoist Tasks

**Dependencies:** Todoist API token in Settings → Integrations → Todoist.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show Tasks | "show tasks", "my tasks", "task list", "show my to-do list" | Opens tasks overlay with Todoist list |
| ✅ | Read My Tasks | "what are my tasks", "what do I need to do", "read my tasks" | Speaks pending tasks |
| ✅ | Add Task | "add task [text]", "new task [text]", "add [text] to my list" | Creates task in Todoist Inbox |
| ✅ | Complete Task | "complete task [name]", "done with [name]", "mark [name] as done" | Marks task complete by fuzzy title match |
| ✅ | Overdue Tasks | "overdue tasks", "what is overdue", "late tasks" | Lists overdue tasks |
| ✅ | **Proactive: Morning overdue** | *automatic 8:30–9:30am* | Announces overdue tasks once per morning |

---

## 7. Weather

**Dependencies:** WeatherKit capability must be added in Xcode (Target → Signing & Capabilities → + WeatherKit). Location permission required at runtime. macOS 13+ required.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ⚠️ | Current Weather | "weather", "what's the weather", "how hot is it", "will it rain", "do I need an umbrella" | Speaks current temperature, conditions, feels-like, humidity. Requires WeatherKit entitlement. |
| ⚠️ | Weather Forecast | "forecast", "weather tomorrow", "weather this week", "weekly forecast", "5-day forecast" | Speaks 2–5 day forecast. Same requirements. |
| ✅ | **Proactive: Morning briefing** | *automatic 7:00–8:00am* | "Good morning — it's [temp] in [city], [conditions]." Once per day. |
| ✅ | **Proactive: Severe weather** | *automatic, urgent* | Fires immediately on storm/blizzard/freezingRain/hurricane — bypasses quiet hours. |
| ✅ | **Proactive: Rain warning** | *automatic before noon* | "Rain expected today" — once per day if rain detected before midday. |

> **⚠️ Action required:** Add WeatherKit capability in Xcode before building, or weather will silently return "I couldn't get the weather right now."

---

## 8. macOS System Control

**Dependencies:** Accessibility permission for some window operations. No extra setup for volume/apps.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Volume Up | "volume up", "louder", "turn it up", "a bit louder" | Increases system volume |
| ✅ | Volume Down | "volume down", "quieter", "turn it down" | Decreases system volume |
| ✅ | Set Volume | "set volume to 50", "set volume to 75 percent" | Sets exact volume |
| ✅ | Mute | "mute", "silence", "no sound" | Mutes system audio |
| ✅ | Unmute | "unmute", "turn sound back on", "restore sound" | Unmutes audio |
| ✅ | What's the Volume | "what volume is it", "current volume", "volume level" | Speaks current volume level |
| ✅ | Open App | "open [app]", "launch [app]", "start [app]" | Opens named application |
| ✅ | Switch to App | "switch to [app]", "go to [app]", "focus [app]" | Brings running app to front |
| ✅ | Quit App | "quit [app]", "force quit [app]" | Terminates app (safety: medium) |
| ✅ | Hide App | "hide [app]" | Hides app windows |
| ✅ | List Running Apps | "what apps are running", "running apps", "which apps are open" | Speaks running app list |
| ✅ | Show Desktop | "show desktop", "hide all windows", "clear the screen" | Shows desktop |
| ✅ | Lock Screen | "lock screen", "lock my screen", "lock the mac" | Locks screen (safety: medium) |
| ✅ | Sleep Display | "sleep display", "turn off the screen", "turn off display" | Sleeps display |
| ✅ | System Settings | "settings", "system settings", "open preferences" | Opens System Settings |
| ✅ | Settings Panes | "wifi settings", "bluetooth settings", "sound settings", "display settings", "privacy settings" | Opens specific settings pane |
| ✅ | Open Folder | "open downloads", "open documents", "open desktop folder", "go home" | Opens named Finder folder |
| ✅ | Open Latest Download | "open latest download", "latest download", "what did I just download" | Opens most recent ~/Downloads file |
| ✅ | Find File | "find file [query]", "find my [query]" | Spotlight search for file |
| ✅ | Open URL | *paste any URL* | Opens URL in default browser |

---

## 9. Overlays & UI

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Focus Mode | "focus mode", "orb mode", "minimal mode", "hide dashboard" | Switches to orb-only minimal view |
| ✅ | Dashboard Mode | "dashboard mode", "show dashboard", "show widgets", "full view" | Switches to widget dashboard |
| ✅ | Show Chat | "show chat", "open chat", "show transcript" | Opens conversation history overlay |
| ✅ | Show Timeline | "show timeline", "timeline", "what did I do today" | Opens activity timeline |
| ✅ | Show Calendar | "show calendar", "open calendar" | Opens today's event timeline overlay |
| ✅ | Show Tasks | "show tasks", "open tasks", "my tasks" | Opens Todoist task list overlay |
| ✅ | Show Memory | "show memory", "open memory", "my memories" | Opens memory browser |
| ✅ | Show Notifications | "what needs my attention", "show notifications" | Opens notification tray |
| ✅ | Close Overlay | "close that", "dismiss", "close chat", "hide that" | Closes top overlay |
| ✅ | Maximise Overlay | "make this bigger", "go fullscreen", "maximise that" | Enlarges current overlay |
| ✅ | Minimise Overlay | "make this smaller", "minimise that" | Shrinks current overlay |
| ✅ | Developer Mode | "developer mode", "show diagnostics", "debug hud" | Shows debug HUD with routing + signal diagnostics |
| ✅ | Edit Responses | "edit responses", "show response playbook" | Opens per-key phrase editor |
| ✅ | Edit Personality | "show personality", "personality settings" | Opens personality settings |
| ✅ | Show Reasoning | "why did you do that", "explain that", "show reasoning" | Shows last intent reasoning trace |
| ✅ | Help | "help", "what can you do", "what are your capabilities", "list commands" | Speaks capability summary |

**Available overlay kinds:** `news`, `camera`, `screen`, `memory`, `chat`, `timeline`, `reasoning`, `article`, `notifications`, `proactiveAlert`, `calendar`, `tasks`, `test`

---

## 10. Proactivity & Notifications

The proactivity engine runs continuously in the background. It gates signals through: **dedupe → daily cap → per-source cooldown → quiet hours (23:00–07:00) → priority filter**.

| Status | Source | What triggers | Spoken alert |
|--------|--------|--------------|-------------|
| ✅ | News | Breaking/high-priority article detected | Headline + brief |
| ✅ | Calendar | Meeting in ~10 min | "Heads up — [meeting] starts in about 10 minutes" |
| ✅ | Calendar | Meeting in ~1 min | "[Meeting] is starting now" |
| ✅ | Todoist | Overdue tasks at 8:30–9:30am | "You have N overdue tasks: [names]" |
| ✅ | GitHub | New PR review request | "You have a PR review request in [repo]: [title]" |
| ✅ | GitHub | @mention in issue/PR | "You were mentioned in [repo]: [title]" |
| ✅ | GitHub | Assigned to issue/PR | "You've been assigned to [title]" |
| ✅ | Home Assistant | Door/window left open >N min | "The front door has been open for 5 minutes" |
| ✅ | Home Assistant | Lock left unlocked >N min | "Front door lock has been unlocked for 10 minutes" |
| ✅ | Home Assistant | Motion detected (away from home) | "Motion detected in living room" |
| ✅ | Home Assistant | Smoke / CO / water sensor triggered | "⚠️ Smoke detector triggered in kitchen" (urgent, bypasses quiet hours) |
| ✅ | Home Assistant | Device went offline | "Kitchen sensor went offline" |
| ✅ | Home Assistant | Vacuum finished or errored | "Vacuum has finished cleaning" |
| ✅ | Shopify | New order placed | "New Shopify order #1234 — £45.99 from [customer]" |
| ✅ | Shopify | Low inventory threshold crossed | "Product [X] has only 2 units left" |
| ✅ | Timers | Named timer expired | "Your pasta timer is done!" |

**Voice controls for proactivity:**

| Status | Feature | Voice triggers |
|--------|---------|---------------|
| ✅ | Pause all | "pause proactivity", "pause notifications", "stop notifying me" |
| ✅ | Resume all | "resume proactivity", "resume notifications" |
| ✅ | Mute news 1hr | "mute news for an hour", "snooze news alerts" |
| ✅ | Mute news | "mute news", "stop news alerts" |
| ✅ | Unmute news | "unmute news", "enable news alerts" |
| ✅ | Dismiss latest | "dismiss that", "never mind", "ignore that" |
| ✅ | Open latest | "open that", "show me that", "open that alert" |
| ✅ | That was useful | "that was useful", "good notification" — saves preference |
| ✅ | Not useful | "not useful", "bad notification" — saves negative preference |
| ✅ | Never this topic | "don't tell me about this", "stop telling me about this" |
| ✅ | Always this topic | "always tell me about this" |

**Per-source toggles** in Settings → Proactivity: calendar / todoist / github / news / shopify / ha-doors / ha-motion / ha-sensors / ha-device-offline on/off.

---

## 11. Memory

**Dependencies:** SQLite database auto-created at `~/Library/Application Support/JarvisMac/jarvis.db`.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Remember Last | "save this", "save that", "remember that", "note this" | Stores last spoken response |
| ✅ | Remember This | "remember [text]" | Stores arbitrary text |
| ✅ | Show Memory | "show memory", "open memory", "my memories" | Opens memory browser overlay |
| ✅ | What Do You Remember | "what do you remember", "what have you remembered" | Speaks recent memories |
| ✅ | Search Memory | "search memory for [query]", "find notes about [query]" | Full-text search (SQLite FTS) |
| ✅ | Search Again | "search again", "find again" | Repeats last memory search |
| ✅ | What Was I Doing | "what was I doing", "what was I working on", "what have I been doing" | Recalls recent activity from context snapshots |
| ✅ | Recent Activity | "recent activity", "recent sessions" | Shows recent commands and context |
| ✅ | Conversation Summaries | *automatic* | LLM compresses each session into a 2–3 sentence summary stored in MemoryStore tagged `conversation_summary,auto`. Fires on session end + daily. Injected into LLM context via hybridSearch. |
| ✅ | Semantic Memory Search | "search memory for [query]" | `NLEmbedding.sentenceEmbedding` vector search (cosine similarity, threshold 0.25, max 500 entries). Persisted to `semantic_index.json`. hybridSearch combines FTS + semantic, deduplicates. |

---

## 12. Identity & Personal Facts

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | My Name | "what is my name", "who am I" | Speaks `Preferences.userName` |
| ✅ | Assistant Name | "what is your name", "who are you", "what are you called" | Speaks assistant name (default: Jarvis) |
| ✅ | What Do You Know About Me | "what do you know about me", "what have you learned about me" | Speaks facts from preferences + memory |

---

## 13. Operating Modes

| Status | Mode | Voice triggers | Description |
|--------|------|---------------|-------------|
| ✅ | Normal | "normal mode", "back to normal", "default mode" | Full TTS, all responses |
| ✅ | Concise | "concise mode", "be concise", "shorter responses" | Minimal response style |
| ✅ | Silent | "silent mode", "go silent", "no talking", "text only" | No TTS except critical messages |
| ✅ | Ambient | "ambient mode", "go ambient", "background mode" | Proactive updates, no interruptions |

---

## 14. Listening Lifecycle

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Stop Listening | "stop listening", "go quiet", "go to sleep", "sleep", "disable wake word" | Mutes wake-word detection entirely |
| ✅ | Start Listening | "start listening", "wake up", "resume listening", "enable listening" | Re-enables wake word |
| ✅ | Stop Talking | "stop talking", "be quiet", "shut up", "stop", "enough" | Immediately cancels current TTS (barge-in) |
| ✅ | Repeat Last | "repeat that", "say that again", "say again" | Re-speaks last response |
| ✅ | Can You Hear Me | "can you hear me", "are you there", "hello Jarvis" | Sanity check — confirms audio is live |
| ✅ | Are You Listening | "are you listening", "still listening" | Confirms listening state |

---

## 15. Daily Briefing

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Daily Briefing | "daily briefing", "morning briefing", "brief me", "catch me up", "what did I miss", "rundown", "what's new", "what's going on today" | Combined spoken summary: top news + calendar events + task count + current weather |

---

## 16. Small Talk & Status

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | What Time Is It | "what time is it", "time", "current time", "time check" | Speaks current time |
| ✅ | What Day Is It | "what's the date", "what day is it", "today's date" | Speaks current date |
| ✅ | Status | "system status", "how are you", "status" | Brief system health summary |
| ✅ | Show Attention State | "show attention state" | Shows attention engine / presence detection state |
| ✅ | Why Did You Do That | "why did you do that", "explain that" | Shows reasoning trace for last action |

---

## 17. GitHub

**Dependencies:** GitHub Personal Access Token in Settings → Integrations. Token needs `notifications` scope.

| Status | Feature | Voice triggers / Description |
|--------|---------|------------------------------|
| ✅ | PR review requests | *automatic* — announces new review requests (priority: high) |
| ✅ | @mentions | *automatic* — announces mentions in issues/PRs (priority: normal) |
| ✅ | Assignments | *automatic* — announces when assigned to an issue/PR |
| ✅ | GitHub Overlay | "show github", "show my pull requests", "show my prs" — dedicated overlay with Review Requests / Assigned / Mentions / Other sections; tap to open in browser |
| ✅ | Check GitHub | "any new github notifications", "any review requests" — speaks unread count + top items |

---

## 18. Multi-Turn Conversations

Jarvis can ask clarifying questions and wait for your answer before executing.

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | HA entity disambiguation | "Turn on the lights" (bare) → "Which lights — living room, bedroom, kitchen, or all?" → user picks room → executes correctly |
| ✅ | HA turn-off disambiguation | Same pattern for turning off when entity is ambiguous |
| ✅ | Task add (empty text) | "Add a task" (no text) → "What task should I add?" → captures reply via LLM |
| ✅ | Reminder add (empty text) | "Remind me" (no what) → "What would you like me to remind you about?" → captures reply |
| ✅ | `.choice` follow-up type | `FollowUpResolver` handles choice lists with fuzzy match + re-ask on no-match |

---

## 19. Pinnable Overlays

| Status | Feature | Voice triggers / Description |
|--------|---------|------------------------------|
| ✅ | Pin overlay | "pin this", "pin that", "pin overlay" — overlay survives "close" voice commands and mode switches |
| ✅ | Unpin overlay | "unpin this", "unpin overlay" — restores normal close behaviour |
| ✅ | Pin button in title bar | Visual pin icon in overlay header — yellow when pinned |

---

## 20. HA Automations by Voice

**Dependencies:** Home Assistant configured (same as §4).

| Status | Feature | Voice triggers |
|--------|---------|---------------|
| ✅ | Run automation | "run automation [name]", "trigger automation [name]", "activate automation [name]" — resolves entity then calls `automation.trigger` |

---

## 21. Wi-Fi and Bluetooth

| Status | Feature | Voice triggers | Notes |
|--------|---------|---------------|-------|
| ⚠️ | Turn Wi-Fi on | "turn on wifi", "enable wifi", "wifi on" | Uses `networksetup -setairportpower en0 on` — may need Accessibility permission |
| ⚠️ | Turn Wi-Fi off | "turn off wifi", "disable wifi", "wifi off" | Same |
| ⚠️ | Turn Bluetooth on | "turn on bluetooth", "enable bluetooth", "bluetooth on" | Requires `blueutil` Homebrew tool or falls back to opening System Settings |
| ⚠️ | Turn Bluetooth off | "turn off bluetooth", "disable bluetooth", "bluetooth off" | Same |

> **⚠️ Wi-Fi:** install `blueutil` via `brew install blueutil` for reliable Bluetooth toggling.

---

## 22. Dual Camera

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Dual camera sessions | `CameraManager` supports `.primary` (face cam) and `.secondary` (desk cam) simultaneously |
| ✅ | Desk camera setting | Settings → Vision: "Desk Camera" picker maps a second device to the secondary role |
| ✅ | Auto-start on launch | If `deskCameraUID` is set, secondary session starts automatically |

---

## 23. Unmatched Command Learning

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Frequency deduplication | Repeated unknown phrases increment a counter instead of creating duplicate entries |
| ✅ | LLM resolution stored | When the LLM resolves an unknown command, the interpretation is saved alongside the entry |
| ✅ | Enhanced view | Unmatched Commands view shows ×N frequency badge and "AI resolved: …" hint for each entry |

---

## 24. Streaming Partials (Lower Latency)

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Early-exit on partial | `FastResponseRouter` runs on every partial transcript with ≥3 words. Confidence ≥0.92 → cancels STT, speaks immediately, saves 300–800ms |
| ✅ | Instant-intent allow-list | Early exit only for parameter-free intents (tell time, date, stop talking, can you hear me, etc.) — entity commands use full transcript |

---

## 25. Wake Word Watchdog

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Auto-restart | 60-second polling loop detects `isRunning = false` and restarts wake word service automatically |
| ✅ | Lifecycle-safe | Watchdog cancelled and restarted on every `rebuildWakeWord()` call — never monitors a torn-down service |

---

## 26. Personality & Memory in LLM

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Personality in every LLM call | `PersonalityContextBuilder.buildSystemPrompt()` now produces structured preamble (name, honorific, formality, humour) injected into every `tryLLMFallback` call |
| ✅ | Memory in LLM context | Top-3 relevant memories fetched and appended to every LLM system prompt via `ContextEngine` |

---

## 28. Android / WebSocket Bridge

**Dependencies:** Port + optional auth token in Settings. Android companion app on phone.

| Status | Feature | Description |
|--------|---------|-------------|
| ✅ | Continue From Android | "continue from phone" — picks up context handed off from Android | 
| ✅ | Open URL from Android | Remote URL open via WebSocket `openURL` command |
| ✅ | Remember From Android | Remote memory save via `rememberThis` command |
| ✅ | HA commands from Android | Home Assistant service calls via WebSocket bridge |

---

## 19. Timers & Stopwatch

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Set Timer | "set a timer for 5 minutes", "5 minute timer", "timer for 30 seconds" | Creates named or unnamed countdown timer |
| ✅ | Named Timer | "set a timer called pasta for 8 minutes", "timer named workout for 20 minutes" | Multiple named timers simultaneously |
| ✅ | Timer Status | "how long on the timer", "timer status", "how much time is left" | Speaks remaining time for active timers |
| ✅ | Cancel Timer | "cancel the timer", "cancel the pasta timer" | Cancels a named or the current timer |
| ✅ | Cancel All Timers | "cancel all timers" | Cancels all active timers |
| ✅ | Start Stopwatch | "start stopwatch", "start timing" | Starts elapsed timer |
| ✅ | Stop Stopwatch | "stop stopwatch", "stop timing" | Stops and speaks elapsed time |
| ✅ | Stopwatch Status | "stopwatch status", "how long has it been" | Speaks current elapsed time |
| ✅ | Timer Expiry Alert | *automatic* | Speaks "[name] timer is done!" + fires ProactivitySignal (`.system`, `.urgent`) |

---

## 20. Clipboard Integration

**Dependencies:** No extra setup. Paste requires Accessibility permission for some apps.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Read Clipboard | "what's in my clipboard", "read my clipboard", "what's copied" | Speaks current clipboard text (up to 200 chars) |
| ✅ | Copy Last Response | "copy that", "copy response", "copy that to clipboard" | Copies last Jarvis TTS response to clipboard |

---

## 21. Spotify Music Control

**Dependencies:** Spotify personal access token in Settings → Integrations → Spotify.  
Get a token from `developer.spotify.com` → your app → OAuth Playground.  
Required scopes: `user-read-playback-state user-modify-playback-state`

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Play Music | "play [artist/song]", "play some music", "play Spotify" | Searches for track/artist and starts playback |
| ✅ | Pause | "pause music", "pause Spotify", "pause" | Pauses current playback |
| ✅ | Resume | "resume music", "resume Spotify", "unpause" | Resumes paused playback |
| ✅ | Next Track | "next track", "skip song", "next" | Skips to next track |
| ✅ | Previous Track | "previous track", "go back", "last song" | Goes to previous track |
| ✅ | What's Playing | "what's playing", "what song is this", "currently playing" | Speaks current track + artist |
| ✅ | Shuffle On | "shuffle on", "turn on shuffle" | Enables shuffle mode |
| ✅ | Shuffle Off | "shuffle off", "turn off shuffle", "no shuffle" | Disables shuffle mode |
| ✅ | Set Volume | "Spotify volume 50", "set Spotify volume to 70" | Sets Spotify playback volume |

---

## 22. Shopify Integration

**Dependencies:** Shopify Admin access token + shop domain in Settings → Integrations → Shopify.  
Create a private app in your Shopify admin to get the Admin API access token.

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show Shopify Overlay | "show Shopify", "Shopify dashboard", "my store" | Opens Shopify overlay with revenue, unfulfilled orders, recent activity |
| ✅ | Recent Orders | "any new orders", "show my orders", "Shopify orders" | Speaks count + total value of recent orders |
| ✅ | Unfulfilled Orders | "what needs fulfilling", "unfulfilled orders" | Speaks unfulfilled order count |
| ✅ | Today's Revenue | "today's revenue", "how much today", "Shopify revenue" | Speaks today's total revenue |
| ✅ | Store Status | "Shopify status", "store status" | Summary of today's orders + revenue |
| ✅ | **Proactive: New order** | *automatic* | "New Shopify order #1234 — £45.99 from [customer]" |
| ✅ | **Proactive: Low stock** | *automatic* | "Product [X] has only N units left" (threshold configurable in Settings) |

---

## 23. Home Assistant Overlay

**Dependencies:** Home Assistant configured (same as §4).

| Status | Feature | Voice triggers | Description |
|--------|---------|---------------|-------------|
| ✅ | Show Home Overlay | "home panel", "home overlay", "smart home overlay", "show devices", "my devices" | Opens room-grouped entity grid: lights, switches, locks, climate, covers |
| ✅ | Tap-to-toggle | *touch/click* | Tap any entity in overlay to toggle it (light/switch/lock/cover) |
| ✅ | Room grouping | *automatic* | Entities grouped by room derived from entity_id prefix (e.g. `light.living_room_lamp` → "Living Room") |
| ✅ | HA Proactivity → Home overlay | *automatic* | HA state alerts now open `.home` overlay instead of generic alert card |

---

## 24. Planned Features

See **`TODO.md`** for full implementation specs, file names, and code patterns for each item below.

### Immediate (next sprint)

| Priority | Feature | TODO ref | Description |
|---------|---------|----------|-------------|
| ✅ High | Obsidian Vault Integration | Sprint E | Full vault tie-in: local markdown indexing, FTS + NLEmbedding hybrid search, RAG injection into every LLM query, voice note creation/append, proactivity alerts for watch-tagged and recently-modified notes, overlay browser with wikilink navigation. Settings: vault picker, LLM context toggle, max context notes, watch tags. |
| 🔲 High | Email Integration | A2 | Apple Mail AppleScript (recommended) or IMAP direct. Proactivity: VIP senders, unread spike, "urgent" keyword. `SignalSource.email` defined. |
| 🔲 Low | Apple Notes | A12 | "Create a note: [text]" via AppleScript — easy win, no API key needed. |

### Future sprints

| Priority | Feature | TODO ref | Description |
|---------|---------|----------|-------------|
| 🔲 Medium | Ambient Vision Loop | A6 | `AmbientVisionService` — background camera frame analysis. Detects presence change, desk events, escalates to LLM only on change. |
| 🔲 Medium | Gesture Control | A5 | `VNDetectHumanHandPoseRequest` → pinch/palm/point gestures → overlay interaction. Largest untouched feature. |
| 🔲 Medium | Unified Fullscreen Stage | A7 | Transparent full-screen `NSWindow` layer — Jarvis owns the screen. All overlays render inside it. |
| 🔲 Low | Window Management | A11 | "Move Safari to the left half", "tile side by side". `AXUIElement`. |
| 🔲 Low | Custom Wake Word | — | Sherpa ONNX supports custom models. Currently uses "Jarvis" keyword file. |

---

## Technical Setup Checklist

Before running Jarvis for the first time:

- [ ] **Microphone** — macOS will prompt on first launch
- [ ] **Camera** — macOS will prompt when first camera command is used
- [ ] **Screen Recording** — System Settings → Privacy → Screen Recording → enable JarvisMac
- [ ] **Calendar** — macOS will prompt when first calendar command is used
- [ ] **WeatherKit** — Add capability in Xcode: Target → Signing & Capabilities → + Capability → WeatherKit
- [ ] **Home Assistant** — Settings → Home: enter base URL + long-lived access token
- [ ] **Todoist** — Settings → Integrations: enter API token from todoist.com → Settings → Integrations
- [ ] **GitHub** — Settings → Integrations: enter PAT with `notifications` scope
- [ ] **LLM** — Settings → AI: configure MiniMax API key or LM Studio local URL
- [ ] **Whisper** (optional) — Settings → Speech: set path to local Whisper model for offline STT
- [ ] **Piper TTS** (optional) — Settings → Voice: set Piper executable + model paths for local TTS

---

*This file is the source of truth for what Jarvis can and cannot do. Update it with every sprint.*
