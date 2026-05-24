# Jarvis Feature Help Audit
*Generated: 2026-05-21*
*This document classifies every feature for help documentation purposes.*
*Only features marked ✅ Implemented should appear in user-facing help docs.*

---

## Implemented Features (Ready for Help docs)

### Wake Word Detection
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Audio/SherpaWakeWordService.swift`
- `JarvisMac/Audio/AppleWakeWordService.swift`
- `JarvisMac/Audio/WakeWordService.swift`
**Description:** Jarvis listens passively for the keyword "Jarvis" using either the Sherpa ONNX model (offline, accurate) or Apple's SFSpeechRecognizer (no model needed, always available as fallback).
**How to use:** Just say "Jarvis" to activate. Or press Cmd+Space for push-to-talk.
**Example commands:**
- "Jarvis" (wake word)
- Cmd+Space (push-to-talk shortcut)
**Settings required:** Voice tab → Wake Word settings. Optional: Sherpa model path for better accuracy.
**Known limitations:** Sherpa requires a separately downloaded keyword model file. Without it, Apple SFSpeechRecognizer is used which requires macOS Dictation to be on in System Settings → Keyboard → Dictation.

---

### Persistent Conversation Sessions
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Core/ConversationRuntime.swift`
- `JarvisMac/Conversation/FollowUpResolver.swift`
- `JarvisMac/Conversation/PendingConversationContext.swift`
**Description:** After saying "Jarvis", you stay in conversation for up to 10 minutes. No need to repeat the wake word for follow-up questions. Jarvis can ask clarifying questions and wait for your answer.
**How to use:** Say "Jarvis" once, then continue speaking. Jarvis tracks the context automatically.
**Example commands:**
- "Jarvis" → "Turn on the kitchen lights" → "Also dim them to 40%"
- "Jarvis" → "Add a task for tomorrow" → (Jarvis asks what task) → "Submit the project report"
- "Stop listening" (to end the session)
- "Go quiet" (to mute)
**Settings required:** General tab → "Persistent Conversation" toggle (on by default).
**Known limitations:** Sessions end after 10 minutes of silence. Saying "stop listening" or "go quiet" permanently ends the session until you say "start listening".

---

### Speech Recognition (STT)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Audio/SpeechRecognizer.swift`
- `JarvisMac/Audio/WhisperSpeechRecognizer.swift`
**Description:** Two STT engines available. Apple Speech is always on. Whisper provides local offline transcription with better accuracy for technical terms.
**How to use:** Choose your engine in Voice Settings.
**Settings required:** Voice tab → Speech Engine. For Whisper: path to a .gguf model file.
**Known limitations:** Apple Speech requires internet and macOS Dictation permission. Whisper is offline but requires a model download (~300 MB to 1.5 GB depending on model size).

---

### Text-to-Speech (TTS)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Audio/TextToSpeechService.swift`
- `JarvisMac/Audio/PiperTTS.swift`
**Description:** Jarvis speaks responses using Apple's AVSpeechSynthesizer or Piper ONNX (a high-quality local voice).
**How to use:** Responses are spoken automatically. Configure voice in Voice Settings.
**Example commands:**
- "Stop talking" (interrupt TTS mid-sentence)
**Settings required:** Voice tab → TTS Engine. For Piper: path to piper binary and .onnx model file.
**Known limitations:** Piper requires the piper binary and an ONNX voice model.

---

### Barge-In (Interrupt While Speaking)
**Status:** ✅ Implemented
**Files:** `JarvisMac/Audio/BargeInMonitor.swift`
**Description:** Say "Jarvis" while Jarvis is speaking to interrupt. Jarvis stops TTS and listens to your new command.
**How to use:** Just say "Jarvis" at any time, even while Jarvis is talking.
**Example commands:** "Jarvis" (during TTS)
**Known limitations:** Barge-in sensitivity is not yet user-adjustable (settings field exists but is a placeholder).

---

### Home Assistant Control
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/HomeAssistantRESTClient.swift`
- `JarvisMac/Integrations/HomeAssistantWebSocketClient.swift`
- `JarvisMac/Integrations/HomeEntityAliasStore.swift`
- `JarvisMac/UI/HomeOverlayView.swift`
**Description:** Full smart home control. Turn lights on/off, set brightness and color, lock/unlock doors, control fans, run vacuums, open/close covers, trigger automations. Real-time proactive alerts for doors, motion, smoke, and locks via WebSocket.
**How to use:** Configure HA URL and access token in Settings → Home.
**Example commands:**
- "Turn on the kitchen lights"
- "Dim the bedroom to 30%"
- "Lock the front door"
- "Show home panel"
- "Run the cleaning automation"
- "Mute home alerts for an hour"
- "Show HA diagnostics"
**Settings required:** Home tab → HA Base URL + Long-Lived Access Token.
**Known limitations:** Entity names must match HA friendly names or be configured as aliases in Settings → Home → Aliases.

---

### Calendar (EventKit)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/EventKitCalendarService.swift`
- `JarvisMac/UI/CalendarOverlayView.swift`
- `JarvisMac/Integrations/CalendarProactivityProvider.swift`
**Description:** Read today's calendar events, check next meeting, add reminders. Proactive 10-minute and 1-minute alerts before meetings.
**How to use:** Grant calendar access when prompted.
**Example commands:**
- "What's on my calendar today?"
- "What's my next meeting?"
- "Remind me to call the bank at 3pm"
- "Show calendar"
**Settings required:** Calendar permission (macOS privacy prompt on first use).
**Known limitations:** Read + reminder only. Cannot edit or delete calendar events.

---

### Todoist Tasks
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/TodoistAPIClient.swift`
- `JarvisMac/UI/TasksOverlayView.swift`
- `JarvisMac/Integrations/TodoistProactivityProvider.swift`
**Description:** View tasks, add new tasks, mark tasks complete. Proactive morning alert for overdue tasks.
**How to use:** Add Todoist API token in Settings → Integrations.
**Example commands:**
- "What are my tasks?"
- "Show tasks"
- "Add a task: review the pull request"
- "Mark done: review the pull request"
- "Any overdue tasks?"
**Settings required:** Integrations tab → Todoist API Token.

---

### Weather (WeatherKit)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/WeatherService.swift`
- `JarvisMac/Integrations/WeatherProactivityProvider.swift`
**Description:** Current weather, multi-day forecast, rain warnings. Morning weather briefing 7–8am. Severe weather urgent alerts.
**Example commands:**
- "What's the weather?"
- "Will it rain tomorrow?"
- "5 day forecast"
**Settings required:** Location permission. WeatherKit entitlement in Xcode (developer requirement).
**Known limitations:** Requires the WeatherKit capability to be active on the app's Apple Developer account.

---

### Spotify Playback Control
**Status:** ✅ Implemented
**Files:** `JarvisMac/Integrations/SpotifyAPIClient.swift`
**Description:** Play, pause, skip, previous track, shuffle, adjust volume, see what's playing. Uses a personal access token — no OAuth server needed.
**Example commands:**
- "Play some jazz"
- "Pause"
- "Next track"
- "Set volume to 60%"
- "What's playing?"
- "Turn on shuffle"
**Settings required:** Integrations tab → Spotify Personal Token. Get one from the Spotify Web API OAuth Playground (required scopes: `user-read-playback-state user-modify-playback-state`).
**Known limitations:** Token expires. Must be manually refreshed. Requires Spotify running on some device.

---

### Shopify Store Dashboard
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/ShopifyAPIClient.swift`
- `JarvisMac/UI/ShopifyOverlayView.swift`
- `JarvisMac/Integrations/ShopifyProactivityProvider.swift`
**Description:** View recent orders, today's revenue, fulfillment status, low-stock alerts. New order and low-stock proactive notifications.
**Example commands:**
- "Show my Shopify orders"
- "What's today's revenue?"
- "Any unfulfilled orders?"
- "Show Shopify"
**Settings required:** Integrations tab → Shopify Access Token + Shop Domain.

---

### GitHub Notifications + Intelligence
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/GitHub/GitHubModule.swift`
- `JarvisMac/Integrations/GitHubAPIClient.swift`
- `JarvisMac/UI/GitHubOverlayView.swift`
- `JarvisMac/UI/GitHubDashboardView.swift`
**Description:** Full developer intelligence. View PRs, issues, CI status, stale PRs, code review with LLM analysis, local repo TODO/FIXME counts, roadmap from open issues.
**Example commands:**
- "Check GitHub"
- "Show my open pull requests"
- "Any stale PRs in the jarvis repo?"
- "What are the open issues?"
- "Review the latest PR"
- "Check CI status"
- "GitHub dashboard"
- "How many TODOs are in the codebase?"
**Settings required:** Settings → GitHub tab → Personal Access Token (scopes: `notifications`, `repo`).

---

### Obsidian Vault
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Integrations/ObsidianVaultService.swift`
- `JarvisMac/Integrations/ObsidianNote.swift`
- `JarvisMac/UI/ObsidianOverlayView.swift`
- `JarvisMac/Integrations/ObsidianProactivityProvider.swift`
**Description:** Search and browse your Obsidian vault by voice. Hybrid FTS + semantic search. Create new notes or append to existing ones. Watched tags alert you when notes are tagged with priority tags. Notes are injected as RAG context into LLM queries.
**Example commands:**
- "Search Obsidian for authentication flow"
- "Open my note about SQLite"
- "What do I know about the API design?"
- "Create a note called Sprint Review"
- "Show Obsidian"
**Settings required:** Integrations tab → Obsidian Vault Path.
**Known limitations:** Vault indexing happens on a 2-minute background poll. New notes may not appear immediately.

---

### News Feed + Live Video
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/News/RSSFetcher.swift`
- `JarvisMac/News/NewsOverlayView.swift`
- `JarvisMac/News/LiveNewsPlayerView.swift`
- `JarvisMac/News/NewsStore.swift`
**Description:** RSS/Atom feed reader with configurable sources including Hacker News. Live YouTube/HLS news channel player. LLM-backed headline summarisation and labelling. Proactive news alerts.
**Example commands:**
- "Show me the news"
- "What's happening in tech?"
- "Watch Bloomberg" (if configured)
- "Summarise the news"
- "Open the first story"
- "Mute news for an hour"
**Settings required:** News tab → Add RSS feeds. News tab → Live Channels → add YouTube channel URLs.

---

### Reddit
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Reddit/RedditClient.swift`
- `JarvisMac/Reddit/RedditOverlayView.swift`
- `JarvisMac/Reddit/RedditStore.swift`
**Description:** Browse subreddits, view posts, read comment trees. LLM summarises posts and comment threads. No OAuth — uses Reddit's public JSON API.
**Example commands:**
- "Show Reddit"
- "Open r/programming"
- "Show top Reddit posts"
- "Search Reddit for SwiftUI tips"
- "Summarise this post"
- "What are the comments saying?"
**Settings required:** Reddit tab → Add subreddit sources.
**Known limitations:** No Reddit account integration (no upvoting, no private subs). Rate-limited at ~60 requests/min.

---

### Android Bridge
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Networking/AndroidBridge.swift`
- `JarvisMac/Networking/AndroidEventReceiver.swift`
- `JarvisMac/Networking/TailscaleService.swift`
- `JarvisMac/UI/AndroidOverlayView.swift`
- `JarvisMac/UI/PhoneOverlayView.swift`
**Description:** Full Mac↔Android companion. Make calls, send SMS, WhatsApp messages, WhatsApp voice/video calls, answer/decline/hang up incoming calls, check phone battery, check phone location context, ring phone. Tailscale-based networking with QR pairing.
**Example commands:**
- "Call Mike"
- "Send a WhatsApp to Cath: I'm on my way"
- "WhatsApp video call Mike"
- "Answer it"
- "Decline it"
- "Hang up"
- "What's my phone battery?"
- "Show Android status"
**Settings required:** Network tab → WebSocket port, auth token. Tailscale must be installed on both Mac and Android. Android companion app required.
**Known limitations:** Requires Android companion app (not shipped in this repo). Tailscale must be active on both devices.

---

### Screen Awareness & OCR
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Screen/ScreenCaptureService.swift`
- `JarvisMac/Screen/ScreenAwarenessService.swift`
- `JarvisMac/Screen/ScreenOCRService.swift`
**Description:** Captures the screen via ScreenCaptureKit, runs Vision OCR, detects active app and window title. Can read text aloud, describe what's on screen, detect errors.
**Example commands:**
- "What's on my screen?"
- "Read my screen"
- "What app am I using?"
- "What text do you see?"
- "Capture the screen"
**Settings required:** Screen Recording permission in macOS System Settings → Privacy & Security → Screen Recording.
**Known limitations:** Only captures the primary display. Does not capture password manager or private browser windows (privacy filter).

---

### Ambient Context Engine
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Ambient/AmbientContextEngine.swift`
- `JarvisMac/Ambient/ActiveAppMonitor.swift`
- `JarvisMac/Ambient/WindowContextMonitor.swift`
- `JarvisMac/Ambient/PrivacyFilter.swift`
**Description:** Passively tracks what you're working on. Monitors active app and window title via NSWorkspace (no screenshots unless enabled). Optional screen sampling at 30s intervals. Watch mode boosts to 8s sampling. Privacy-gated.
**Example commands:**
- "What am I working on?"
- "What changed on screen?"
- "What failed on screen?"
- "Watch this" (activates watch mode)
- "Stop watching"
- "Enable ambient context"
- "Show ambient context" (debug overlay)
**Settings required:** Screen Recording permission for screen sampling. Ambient mode can be toggled by voice.
**Known limitations:** App tracking only (no screenshots) unless screen recording is granted and ambient sampling is enabled.

---

### Visual Intelligence / POI Surveillance (Sprint L)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Vision/VisionModule.swift`
- `JarvisMac/Vision/POIHUDView.swift`
- `JarvisMac/Vision/VisionDetectionPipeline.swift`
- `JarvisMac/Vision/CameraFeedManager.swift`
- `JarvisMac/Vision/RTSPStreamManager.swift`
- `JarvisMac/Vision/ThreatClassifier.swift`
- `JarvisMac/Vision/MotionZoneEngine.swift`
- `JarvisMac/Vision/ObjectTracker.swift`
**Description:** Multi-camera surveillance with person and face detection. Grid, focus, and cinematic display modes. Target bounding boxes with threat classification. Motion zone alerts. RTSP stream support for IP cameras. Scene event log. Integrates with ProactivityEngine for motion alerts.
**Example commands:**
- "Show surveillance"
- "Start surveillance"
- "Stop surveillance"
- "What do you see?" (scene description)
- "Who is at the front door?"
- "Any people detected?"
- "Show threat status"
- "Add RTSP camera: Driveway at rtsp://192.168.1.100/stream"
- "Show driveway camera"
**Settings required:** Camera permission. RTSP stream URLs for IP cameras (optional).
**Known limitations:** RTSP stream detection stop loop has a bug (streams may continue in background after stopping surveillance). Built-in detection is person/face only. Richer object detection requires a user-supplied CoreML model.

---

### Spatial Hand Tracking & Gesture Control
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/SpatialInteraction/HandTrackingEngine.swift`
- `JarvisMac/SpatialInteraction/SpatialInteractionCoordinator.swift`
- `JarvisMac/SpatialInteraction/GestureClassifier.swift`
- `JarvisMac/SpatialInteraction/SpatialCursorEngine.swift`
- `JarvisMac/SpatialInteraction/SpatialRadialHUD.swift`
- `JarvisMac/SpatialInteraction/GestureCalibrationStore.swift`
**Description:** Real Apple Vision hand tracking. Index-finger cursor controls overlays. Pinch-and-hold opens a radial action menu (8 actions: news, camera, memory, debug, close, reset, pin, expand). Two-hand spread resizes overlays. Dominant-hand lock, face-contact rejection, accidental-motion suppression, adaptive calibration that learns your hand size.
**How to use:** Works automatically when your hand is visible to the webcam. No setup needed.
**Example commands:**
- "Spatial mode" (shows diagnostics overlay)
- "Close spatial" (disables)
- Settings → Gestures tab for calibration and gesture preferences
**Known limitations:** Requires good lighting for reliable detection. Only one primary gesture action per frame. Two-hand resize requires a 0.5s dwell period to avoid accidental activation.

---

### Timers and Stopwatch
**Status:** ✅ Implemented
**Files:** `JarvisMac/Core/TimerService.swift`
**Description:** Multiple simultaneous named timers. Auto-naming (Timer 1, Timer 2). Stopwatch. Timer expiry triggers TTS announcement and proactivity signal.
**Example commands:**
- "Set a 5 minute timer"
- "Set a timer for 20 minutes called pizza"
- "Set a 30 second timer"
- "Cancel the pizza timer"
- "Cancel all timers"
- "Timer status"
- "Start the stopwatch"
- "Stop the stopwatch"
- "Stopwatch time"

---

### Clipboard
**Status:** ✅ Implemented
**Files:** `JarvisMac/Core/MacSystemController.swift`
**Description:** Read what's on the clipboard, or write text to the clipboard.
**Example commands:**
- "What's on my clipboard?"
- "Copy that to the clipboard"

---

### Memory Management
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Memory/MemoryStore.swift`
- `JarvisMac/Memory/SearchService.swift`
- `JarvisMac/Memory/SemanticMemoryIndex.swift`
**Description:** Persistent memory across sessions. FTS + semantic hybrid search. Conversation summaries are automatically created. You can explicitly save information.
**Example commands:**
- "Remember that I'm using PostgreSQL for the backend"
- "Remember that" (saves last thing Jarvis said)
- "Search my memory for database decisions"
- "What do you remember?"
- "Show recent memories"
**Known limitations:** Semantic search requires NLEmbedding model (built-in, no download). Memory is capped at 500 semantic entries (oldest are pruned).

---

### macOS System Control
**Status:** ✅ Implemented
**Files:** `JarvisMac/Core/MacSystemController.swift`, `JarvisMac/Actions/MacActionExecutor.swift`
**Description:** Volume control, open apps, open system settings, lock screen, show desktop, hide/quit apps, find files, volume/mute/unmute.
**Example commands:**
- "Volume up", "Volume down", "Mute", "Set volume to 50%"
- "Lock the screen"
- "Show the desktop"
- "Open Safari"
- "Quit Slack"
- "Find my latest download"
- "Turn on Wi-Fi"
- "Turn off Bluetooth"
**Known limitations:** Wi-Fi toggle uses `networksetup` CLI. Bluetooth toggle requires `blueutil` installed (`brew install blueutil`).

---

### Personality System
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Personality/PersonalityContextBuilder.swift`
- `JarvisMac/Personality/PersonalityFileStore.swift`
- `JarvisMac/Personality/PersonalityPack.swift`
**Description:** Configurable personality that affects LLM system prompt (formality, humor, honorific, name style) and TTS voice/rate/pitch.
**Example commands:**
- "Show personality settings"
- "Reload personality"
**Settings required:** Settings → Personality tab.

---

### Editable Voice Responses
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Responses/ResponsePlaybook.swift`
- `JarvisMac/Responses/ResponseTemplateStore.swift`
- `JarvisMac/UI/ResponsePlaybookView.swift`
**Description:** Every built-in response phrase is editable. Add alternative phrasings or change defaults. Variable substitution with `{variable_name}` placeholders.
**Example commands:**
- "Show response playbook"
**Settings required:** Settings → Responses tab.

---

### Proactivity Engine
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Core/ProactivityEngine.swift`
- `JarvisMac/Core/ProactivitySignal.swift`
- `JarvisMac/UI/NotificationTrayView.swift`
**Description:** Unified proactivity layer. All integrations (calendar, Todoist, GitHub, HA, weather, Shopify, Obsidian, news) can emit signals. Engine deduplicates, respects quiet hours, per-source mute, and priority ordering. Notification tray shows pending signals.
**Example commands:**
- "What needs my attention?"
- "Show notifications"
- "Clear notifications"
- "Pause proactivity"
- "Resume proactivity"
- "Mute news for an hour"
**Settings required:** Per-source toggles in Settings → General → Proactivity.

---

### Daily Briefing
**Status:** ✅ Implemented
**Files:** `JarvisMac/Core/JarvisController.swift` (`executeDailyBriefing`)
**Description:** Morning summary combining weather, calendar, tasks, and GitHub notifications into a single spoken briefing.
**Example commands:**
- "Daily briefing"
- "Give me my morning briefing"

---

### Operating Modes
**Status:** ✅ Implemented
**Files:** `JarvisMac/Core/CommandModels.swift` (OperatingMode enum)
**Description:** Four modes: Normal (full TTS), Concise (shorter responses), Silent (no TTS unless critical), Ambient (subtle proactivity, no interruptions).
**Example commands:**
- "Normal mode"
- "Concise mode"
- "Silent mode"
- "Ambient mode"

---

### Help System (Living Documentation)
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/Documentation/LivingDocumentationEngine.swift`
- `JarvisMac/UI/HelpOverlayView.swift`
- `JarvisMac/Documentation/BuiltInContributors.swift`
**Description:** Self-updating help that reflects your current configuration. Sections appear/disappear based on which integrations are configured. Searchable. Clickable example phrases copy to clipboard.
**Example commands:**
- "Show help"
- "What can you do?"
- "How do I call someone?"
- "Help me with vision"

---

### Activity Timeline
**Status:** ✅ Implemented
**Files:** `JarvisMac/Timeline/TimelineOverlayView.swift`
**Description:** Searchable, filterable timeline of recent Jarvis activities grouped by hour.
**Example commands:**
- "Show timeline"
- "What did I do today?"

---

### Reasoning Trace
**Status:** ✅ Implemented
**Files:** `JarvisMac/Reasoning/ReasoningTrace.swift`
**Description:** Records each intent resolution with context (active app, attention state, overlays, spoken response). Shown in reasoning overlay for debugging.
**Example commands:**
- "Show reasoning"
- "Why did you do that?"

---

### Debug HUD + Runtime Diagnostics
**Status:** ✅ Implemented
**Files:**
- `JarvisMac/UI/DebugHUDView.swift`
- `JarvisMac/UI/RuntimeDiagnosticsOverlayView.swift`
**Description:** Floating debug HUD with live status. Runtime diagnostics overlay shows all subsystem health, EventStore throughput, current task thread.
**Example commands:**
- "Developer mode"
- "Runtime diagnostics"
- "Subsystem health"

---

## Partial Features (Partially documentable)

### RTSP Camera Feeds
**Status:** ⚠️ Partial
**What works:** Adding RTSP stream URLs, AVPlayer playback, frame extraction for detection (person/face), motion intensity computation, stream connection state tracking.
**What doesn't work yet:** Stopping all detection loops when surveillance is paused — `stopAllDetectionLoops()` has an empty body. Background loops may continue after stopping.
**How to test:** Add an RTSP URL in Settings → Vision → Camera Feeds. Say "Start surveillance" then "Stop surveillance" and check CPU usage.
**Roadmap recommendation:** Phase 1 — Fix `RTSPStreamManager.stopAllDetectionLoops()` to actually cancel running tasks.

### CoreML Object Detection (POI)
**Status:** ⚠️ Partial
**What works:** Full `VNCoreMLRequest` pipeline in `VisionDetectionPipeline`. Model loading via `loadCoreMLModel(at:)`. Label-to-class mapping for 10+ categories.
**What doesn't work yet:** No bundled model. User must supply a YOLO-compatible CoreML model. No Settings UI to configure the model path.
**How to test:** Download a YOLOv8 or NanoYOLO CoreML model, call `VisionModule.shared.loadCoreMLModel(at: "/path/to/model.mlmodel")` in code, then test detection.
**Roadmap recommendation:** Phase 3 — Bundle a lightweight model or add Settings UI for model path.

### Attention Engine
**Status:** ⚠️ Partial
**What works:** `AttentionEngine.swift` is a full rule-based evaluator. Idles monitor, media app detection, fullscreen detection.
**What doesn't work yet:** May not be started or consulted in the main controller flow. Outputs are not visibly gating proactivity decisions.
**How to test:** Say "Show attention state" (intent wired).
**Roadmap recommendation:** Phase 2 — Wire `attention.evaluate()` into proactivity signal scoring.

---

## Stubbed / Placeholder Features (Do NOT document as working)

### Email Integration
**Files:** None (no email implementation files)
**Why stubbed:** There is a single placeholder branch in `JarvisController` (around line 6387) that returns `reply_yes_email_placeholder` / `reply_no_email_placeholder` labels when email-like follow-up context is attempted. No email reading, composing, or sending is implemented. The spoken response says "Email support coming soon."
**Missing:** `EmailService`, Apple Mail AppleScript bindings, `Intent.readEmail`, `Intent.replyToEmail`, email proactivity provider, any email phrase defaults.

### Apple Notes
**Files:** None
**Why stubbed:** Mentioned in CLAUDE.md / TODO.md as planned. No file exists, no intent case, no phrase matches.
**Missing:** Everything.

### Web Search
**Files:** `JarvisMac/LLM/WebSearchProvider.swift` (protocol + NoopProvider only)
**Why stubbed:** `NoopWebSearchProvider` always returns nil. JarvisController's `webSearch` property calls it but always falls through to LLM-only answers. No Brave, DuckDuckGo, or SerpAPI provider exists.
**Missing:** Any real search provider implementation.

### Barge-In Sensitivity Control
**Files:** `JarvisMac/Memory/PreferencesStore.swift` (`bargeInSensitivity` field)
**Why stubbed:** The field comment reads "0.0–1.0 placeholder for future tuning." The Settings slider saves the value but no code reads it from the barge-in logic.
**Missing:** Connecting the stored value to an actual silence/energy threshold in `BargeInMonitor`.

### Keychain Token Storage
**Files:** `JarvisMac/LLM/Keychain.swift`
**Why stubbed:** The file exists but is not imported or called from `PreferencesStore`. All API tokens (HA, Todoist, GitHub, Shopify, Spotify, MiniMax, Gemini) are stored in plain JSON in `~/Library/Application Support/JarvisMac/preferences.json`.
**Missing:** Wiring `Keychain.swift` into `PreferencesStore.save()` and `PreferencesStore.load()` for each token field.

### Motion Zone Default Feed IDs
**Files:** `JarvisMac/Vision/MotionZoneEngine.swift` (line 35)
**Why stubbed:** The default motion zones use `cameraFeedID: UUID()` — a fresh random UUID every launch. These UUIDs will never match any real camera feed ID, so zone alerts never fire from defaults.
**Missing:** Wiring real feed IDs into the default zone descriptors at runtime.

---

## Missing Roadmap Features

### Email Integration (A2)
**Expected behaviour:** Read inbox, announce unread VIP messages, compose and send replies by voice, email-related proactivity provider for important keywords.
**Current state:** Placeholder response only. No implementation files.
**Recommended phase:** Phase 2. `AppleScriptRunner.swift` is already present and functional.

### Apple Notes (A12)
**Expected behaviour:** Create notes, append to existing notes, read note content by voice.
**Current state:** Not started.
**Recommended phase:** Phase 2. Trivial AppleScript: `tell application "Notes" to make new note with properties {name:"...", body:"..."}`.

### Web Search Provider
**Expected behaviour:** Real-time web search (Brave, DuckDuckGo, or SerpAPI) before falling back to LLM for factual queries.
**Current state:** Protocol only, Noop provider always wired.
**Recommended phase:** Phase 1. Protocol is clean — just implement `BraveSearchProvider`.

### Window Management (A11)
**Expected behaviour:** "Move Slack to the left half", "Tile Xcode and Terminal side by side", "Move this window to the second screen".
**Current state:** Not started.
**Recommended phase:** Phase 4. Requires `AXUIElement` accessibility APIs.

### Continuous Ambient Vision (A6)
**Expected behaviour:** Background camera analysis at low frequency. Triggers proactivity signals for scene changes, new people, objects of interest.
**Current state:** `VisionModule` (Sprint L) covers most of this. The gap is a configurable always-on mode with proactivity signal bridge.
**Recommended phase:** Phase 3. Largely available via `VisionModule` — needs wiring into `ProactivityEngine`.

### Bundled CoreML Detection Model
**Expected behaviour:** Person, car, pet, package, backpack detection out of the box without user providing a model.
**Current state:** Pipeline wired, model file required from user.
**Recommended phase:** Phase 3. Bundle a NanoYOLO or MobileNet SSD model.
