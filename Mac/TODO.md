# Jarvis — Build TODO

> Last updated: 2026-05-18  
> Sprint D complete — A1 HA WebSocket Proactivity, A3 Shopify, A4 Home Overlay, A8 Timers, A9 Clipboard, A10 Spotify, A14 Conversation Summaries, A15 Semantic Memory.  
> Audit patches applied (commit bf89376) — P0/P1 bugs fixed (see CLAUDE.md § "Remaining audit items").  
> All moved to FEATURES.md. Remaining Section A items listed below.

---

## ✅ SPRINT C COMPLETED (Section B — all done)

B1 Multi-turn conversations · B2 Memory→LLM · B3 Streaming partials · B4 Weather proactivity · B5 Personality depth · B6 Wake watchdog · B7 Dual camera · B8 Pinnable overlays · B9 GitHub overlay+voice · B10 Wi-Fi/BT toggles · B11 HA automations · B12 Unmatched learning

## ✅ SPRINT D COMPLETED (Section A items done)

A1 HA WebSocket Proactivity Provider · A3 Shopify Integration · A4 Home Assistant Overlay · A8 Timers & Stopwatch · A9 Clipboard Integration · A10 Spotify Music Control · A14 Conversation Summaries · A15 Semantic Memory

All moved to FEATURES.md.

## ✅ AUDIT PATCHES APPLIED (commit bf89376)

**P0 bugs fixed:** ShopifyOverlayView never shown (OverlaySystem wiring) · HA door/lock "left open" timer never firing · Shopify startup TTS flood (isFirstPoll) · openURL bridge opens any URL scheme · NoopWakeWord watchdog falsely healthy · try! crash on fallback DB

**P1 routing fixed:** "stop speaking" routed to modeSilent (now stopTalking) · WiFi/BT "toggle" hardcoded to On · 18 IntentMapping entries missing for Sprint D commands

**P1 WebSocket:** URLSession zombie accumulation on reconnect · No ping/pong keep-alive (NAT drops)

**P2 cleanup:** NSDataDetector constructed per-transcript (now static) · announcedKeys unbounded growth · ProactivityEngine source-gating switch non-exhaustive · preferences.json world-readable (now 0o600/0o700) · speakText bridge no length limit (now 300 chars) · Duplicate home_status phrase definition

**Remaining audit P1–P2 (deferred to security sprint):** API tokens in Keychain · prompt injection markers · ConversationSummariser privacy log · requireWebSocketAuth default · duplicate overlay phrase priority conflicts

---

## SECTION A — REMAINING

---

### A2. Email Integration
**Priority: High**  
**Effort: Medium (2–3 days)**

`SignalSource.email` is defined. Nothing else exists.

**What to build:**

**Option A (recommended): Apple Mail via AppleScript**
- No OAuth, no server config — reads from whatever accounts are in Mail.app
- File: `JarvisMac/Integrations/AppleMailProactivityProvider.swift`
- Use `AppleScriptRunner` (already exists) to query unread count, sender, subject
- Poll every 5 minutes
- Alert on: unread emails from VIP senders, unread count spike (>10 new), keywords in subject ("urgent", "invoice", "order")

**Option B: IMAP direct**
- More powerful, works without Mail.app open
- Needs host/port/credentials in Settings
- File: `JarvisMac/Integrations/IMAPEmailClient.swift`
- Use `Network` framework or third-party IMAP library
- Supports: flag-based VIP detection, keyword filtering, unread monitoring

**Voice commands to add:**
- "Any new emails?" → speaks unread count + top sender
- "Read my emails" → lists top 3 unread
- "Any urgent emails?" → filters by keyword
- Intent cases: `checkEmail`, `readEmails`, `urgentEmails`

**New files:**
- `JarvisMac/Integrations/AppleMailProactivityProvider.swift` (or IMAPEmailClient)
- `JarvisMac/UI/EmailOverlayView.swift` — list of recent emails with sender/subject/time
- Update `OverlaySystem.swift`: add `.email` case
- Update `ProactivitySignal.swift`: `.email → .email` in `preferredOverlayKind`
- Add `emailVIPSenders: [String]`, `emailKeywords: [String]` to `Preferences`
- Settings section: email source toggle, VIP senders list, keyword list

---

### A5. Gesture Control — Hand Tracking + Spatial UI
**Priority: Medium (long-term vision)**  
**Effort: Large (full sprint, 1–2 weeks)**

Entire area not started. This is the most technically complex untouched feature.

**Phase 1: Hand detection (detect presence of hands in camera frame)**
File: `JarvisMac/Vision/HandTrackingService.swift`
- Use `VNDetectHumanHandPoseRequest` (Vision framework, macOS 12+)
- Run on camera frames from `CameraManager`
- Detect: hand present / not present, rough position (left/right/center of frame)
- Output: `HandTrackingEvent` (handDetected, handPosition, fingerCount)

**Phase 2: Gesture recognition**
File: `JarvisMac/Vision/GestureClassifier.swift`
- Input: `VNHumanHandPoseObservation` landmark positions
- Classify: pinch (thumb + index close), open palm (stop), point (index extended), fist
- Output: `GestureEvent` (pinch, openPalm, point, fist)

**Phase 3: Screen coordinate mapping**
- Map hand position in camera frame → screen coordinates
- Factor in camera FOV and user distance
- Output: `CGPoint` in screen space for hover/click targeting

**Phase 4: Overlay interaction**
File: `JarvisMac/UI/GestureOverlayInteraction.swift`
- Hover: highlight overlay element under hand cursor
- Pinch: select / click highlighted element
- Pinch + drag: move overlay
- Two-hand pinch expand/contract: resize overlay
- Open palm held: pause / dismiss

**Phase 5: Cursor layer**
- Render a subtle hand-cursor indicator in the Jarvis stage layer
- Appears only when hands detected

**New files:**
- `JarvisMac/Vision/HandTrackingService.swift`
- `JarvisMac/Vision/GestureClassifier.swift`
- `JarvisMac/UI/GestureOverlayInteraction.swift`
- `JarvisMac/UI/GestureCursorView.swift`

**Settings:** gesture sensitivity, hand cursor toggle, which camera to use for gesture

---

### A6. Continuous Ambient Vision Loop
**Priority: Medium**  
**Effort: Medium (2–3 days)**

Camera currently only runs on demand (you ask "what do you see"). Vision needs to be continuous and event-driven.

**What to build:**  
File: `JarvisMac/Vision/AmbientVisionService.swift`

Runs a background loop (configurable interval: 5s, 10s, 30s). On each tick:
1. Captures frame from desk camera (or face camera if desk not available)
2. Runs lightweight Apple Vision checks: presence, motion delta, object change
3. Only escalates to LLM vision if something changed (motion threshold exceeded, new person detected, new object appeared)
4. Emits `AmbientVisionEvent` to `ProactivityEngine` if significant

**Events to detect:**
- Person entered/left frame
- Package/object appeared on desk
- Screen content changed significantly (if screen watch active)
- User appears to be away from desk > 30 min (no presence)
- User appears stressed/focused (future: facial expression — low priority)

**Integration:**
- `JarvisController` owns `AmbientVisionService` alongside existing `CameraAwarenessService`
- Start/stop tied to camera permission + ambient mode toggle
- Settings: ambient vision on/off, detection sensitivity, interval
- Does NOT constantly speak — feeds `ProactivityEngine` with low-priority signals
- Add `ambientVisionEnabled` to `Preferences`

**New files:**
- `JarvisMac/Vision/AmbientVisionService.swift`
- `JarvisMac/Vision/AmbientVisionEvent.swift`

---

### A7. Unified Fullscreen Stage
**Priority: Medium (big UX shift)**  
**Effort: Large**

Currently Jarvis is floating panels over the macOS desktop. The vision is a unified HUD layer that *owns* the screen when active.

**What to build:**

**Option A: Transparent fullscreen NSWindow layer**
- A `.mainMenu`-level or above `NSWindow` covering full screen, fully transparent background
- All Jarvis UI (orb, overlays, gesture cursor) renders into this single window
- macOS desktop shows through the transparent areas
- No titlebar, no dock interaction
- Activated via hotkey or "enter Jarvis mode"

**Option B: Separate Space**
- Jarvis lives in its own macOS Space (virtual desktop)
- User swipes to it
- Full-screen SwiftUI stage with dark/ambient background
- Easier to implement, less immersive

**Recommendation:** Option A for the full vision. Option B as MVP.

**Files to create/modify:**
- `JarvisMac/UI/JarvisStageWindow.swift` — the full-screen NSWindow host
- `JarvisMac/UI/JarvisStageView.swift` — root SwiftUI view for the stage
- Modify `AppDelegate` / main app setup to manage stage window lifecycle
- All existing overlays become views within the stage, not separate windows
- Add stage mode toggle: "enter Jarvis mode" / "exit Jarvis mode"

---

### A11. Window Management
**Priority: Low-Medium**  
**Effort: Small-Medium**

Currently Jarvis can open/focus/hide/quit apps but cannot control window position or size.

**Voice commands:**
- "Move Safari to the left half" / "Move to the right side"
- "Make this window bigger" / "Fullscreen this"
- "Tile Safari and Chrome side by side"
- "Move to the next display"
- "Minimise all windows"

**Implementation:**
- `MacSystemController` extension using `AXUIElement` (requires Accessibility permission)
- `AXUIElementSetAttributeValue` for position and size
- macOS 15+ can use Stage Manager API
- For tiling: calculate half-screen rects from `NSScreen.main.visibleFrame`

---

### A12. Apple Notes Integration
**Priority: Low**  
**Effort: Small**

**Voice commands:**
- "Create a note: [text]"
- "Add to my notes: [text]"
- "What are my recent notes?"
- "Find my note about [topic]"

**Implementation:**
- AppleScript via `AppleScriptRunner` (already exists): `tell application "Notes" to make new note`
- No API key needed
- `createNote(body:)`, `searchNotes(query:)` methods
- Add to `MacSystemController` or new `NotesService`

---

### A13. HA Automations by Voice *(done in Sprint C as B11)*

Already implemented. "Run automation [name]" → `homeRunAutomation(name:)` intent. See FEATURES.md §20.

---

## PRIORITY ORDER (remaining Section A items)

### Completed in Sprint E
- **Obsidian vault** ✅ — Full knowledge-base integration. See FEATURES.md and CLAUDE.md Sprint E notes.

### Immediate (Sprint F)
1. **A2** — Email integration (Apple Mail AppleScript + proactivity)
2. **A12** — Apple Notes (easy win via AppleScript)

### Future sprints
3. **A6** — Continuous ambient vision loop
4. **A11** — Window management (AXUIElement)
5. **A5** — Gesture control (VNDetectHumanHandPoseRequest)
6. **A7** — Unified fullscreen stage

---

*Update this file after every sprint — move completed items to FEATURES.md and delete them here.*
