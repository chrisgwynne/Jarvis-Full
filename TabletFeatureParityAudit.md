# Tablet Feature Parity Audit
> Generated: second-pass tablet workstation implementation
> Phone shell: `AppNavHost` + phone-specific composables
> Tablet shell: `TabletNavHost` → AssistantSidebar (35%) + DetailPane (65%)

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Full parity — same capability available on tablet |
| 🟡 | Partial parity — available but with UI/UX differences |
| ❌ | Not yet implemented on tablet |
| 🚫 | Not applicable / intentionally excluded |

---

## Feature Matrix

| Feature | Phone | Tablet | Status | Notes |
|---------|-------|--------|--------|-------|
| **Core Voice** | | | | |
| Wake word detection | ✅ | ✅ | ✅ | Shared `JarvisService` / `JarvisRuntime` |
| Manual trigger (listen button) | ✅ | ✅ | ✅ | `TabletAssistantPanel` → `vm.triggerListen()` |
| STT / speech recognition | ✅ | ✅ | ✅ | Shared pipeline |
| LLM call & response | ✅ | ✅ | ✅ | Shared `JarvisRuntime` |
| TTS playback | ✅ | ✅ | ✅ | Shared `TtsDispatcher` |
| Silence / mute | ✅ | ✅ | ✅ | `vm.silenceService()` in sidebar |
| Service start / stop | ✅ | ✅ | ✅ | Service control chips in sidebar |
| **Conversation** | | | | |
| Conversation history feed | ✅ | ✅ | ✅ | `TabletAssistantDetailPanel` — full bubble feed |
| Auto-scroll to latest turn | ✅ | ✅ | ✅ | `LaunchedEffect(count)` → `animateScrollToItem` |
| Turn count indicator | ✅ | 🟡 | 🟡 | Tablet shows count in header; phone shows inline |
| **Action Planner / Routing** | | | | |
| Live Jarvis state indicator | ✅ | ✅ | ✅ | `StateBadge` in sidebar |
| Action step timeline | ❌ | ✅ | ✅ | `TabletActionPlanPanel` — tablet-only feature |
| Route history (recent routes) | ❌ | ✅ | ✅ | `TabletActionPlanPanel` — sourced from `LocalRouteDiagnostics` |
| Multi-step plan visualisation | ❌ | ✅ | ✅ | Shows last succeeded plan from `ActionJournalDao` |
| **Messaging / SMS** | | | | |
| Read last SMS | ✅ | ✅ | ✅ | Via `RecentMessageContext` → voice command |
| Reply to SMS | ✅ | ✅ | ✅ | Voice command → existing tool |
| Message context card | ✅ | ✅ | ✅ | `TabletMessagesPanel` shows last message context |
| Quick open Messages / WhatsApp | 🟡 | ✅ | ✅ | Tablet has dedicated action chips |
| **WhatsApp** | | | | |
| Send WhatsApp message | ✅ | ✅ | ✅ | Via voice + `JarvisAccessibilityService` auto-send |
| WhatsApp auto-send | ✅ | ✅ | ✅ | Shared `JarvisAccessibilityService.arm()` |
| **Email** | | | | |
| Compose email with fields | ❌ | ✅ | ✅ | `TabletEmailPanel` — To/CC/BCC/Subject/Body |
| Draft auto-save | ❌ | ✅ | ✅ | `TabletEmailDraftStore` → SharedPreferences |
| Draft recovery on reopen | ❌ | ✅ | ✅ | ViewModel loads draft on init |
| Attachments from file context | ❌ | ✅ | ✅ | `TabletFileContextStore` → `attachSelectedFile()` |
| Multiple attachments | ❌ | ✅ | ✅ | `ACTION_SEND_MULTIPLE` with URI array |
| CC / BCC fields | ❌ | ✅ | ✅ | Expandable CC/BCC section |
| Open Gmail directly | 🟡 | ✅ | ✅ | Quick-launch chip in email send bar |
| Send via Android intent | ✅ | ✅ | ✅ | `ACTION_SENDTO` (no attachments) / `ACTION_SEND` |
| Voice-fill email fields | ✅ | ✅ | ✅ | Existing voice tools pipe into compose ViewModel |
| **Files** | | | | |
| Recent files browser | ❌ | ✅ | ✅ | `TabletFileTrayPanel` — MediaStore query, 60 files |
| Select file as active context | ❌ | ✅ | ✅ | `TabletFileContextStore` — process-wide singleton |
| Open file with viewer | ❌ | ✅ | ✅ | `ACTION_VIEW` with `FLAG_GRANT_READ_URI_PERMISSION` |
| Share file (generic) | ❌ | ✅ | ✅ | `ACTION_SEND` chooser |
| Share to WhatsApp | ❌ | ✅ | ✅ | Direct WhatsApp + fallback to chooser |
| Copy file URI to clipboard | ❌ | ✅ | ✅ | `ClipboardManager` |
| Attach file to email | ❌ | ✅ | ✅ | One-tap from file panel navigates to email + attaches |
| File type icons | ❌ | ✅ | ✅ | `iconForMime()` covers image/video/audio/pdf/doc/sheet/archive |
| **App Control** | | | | |
| Launch app by name (voice) | ✅ | ✅ | ✅ | Shared `OpenAppTool` + `AppResolver` |
| Quick-launch grid | ❌ | ✅ | ✅ | 12-app grid in `TabletAppControlPanel` |
| Current foreground app display | ❌ | ✅ | ✅ | Live poll of `JarvisAccessibilityService.currentForegroundPackage` |
| Recent apps list | ❌ | ✅ | ✅ | Rolling 6-entry history tracked in panel |
| Go Home (global action) | ✅ | ✅ | ✅ | `GLOBAL_ACTION_HOME` button |
| Go Back (global action) | ✅ | ✅ | ✅ | `GLOBAL_ACTION_BACK` button |
| Show Recents (global action) | ✅ | ✅ | ✅ | `GLOBAL_ACTION_RECENTS` button |
| Take screenshot | ✅ | ✅ | ✅ | `GLOBAL_ACTION_TAKE_SCREENSHOT` button |
| Accessibility status / fix CTA | ❌ | ✅ | ✅ | Diagnostics card with deep-link to settings |
| **Home Assistant** | | | | |
| HA command via voice | ✅ | ✅ | ✅ | Shared `HomeAssistantTool` |
| HA context display | ✅ | ✅ | ✅ | `TabletHomeAssistantPanel` recent HA card |
| Quick HA command tiles | ❌ | ✅ | ✅ | 2-col grid in `TabletHomeAssistantPanel` |
| **Calendar** | | | | |
| Read calendar events (voice) | ✅ | ✅ | ✅ | Shared `CalendarTool` |
| Upcoming events view | ❌ | ✅ | ✅ | `TabletCalendarPanel` — next 7 days from `CalendarContract` |
| All-day event indicator | ❌ | ✅ | ✅ | Shown in calendar panel |
| **Diagnostics** | | | | |
| Full diagnostics panel | ✅ | ✅ | ✅ | `TabletDiagnosticsPanel` (inline, no scaffold) |
| STT mode / recogniser count | ✅ | ✅ | ✅ | Shared `DeviceStateStore` |
| Permission health dots | ✅ | ✅ | ✅ | Also in sidebar mini view |
| Route audit log | ✅ | ✅ | ✅ | `LocalRouteDiagnostics` entries |
| **Settings** | | | | |
| Full settings screen | ✅ | ✅ | ✅ | Reuses `SettingsScreen(onBack = …)` |
| **Overlays / Floating UI** | | | | |
| Floating overlay (phone) | ✅ | 🚫 | 🚫 | Tablet has persistent split-pane layout instead |
| **Wake Word** | | | | |
| Wake word ("Jarvis") | ✅ | ✅ | ✅ | Shared service |
| **Proactivity Engine** | | | | |
| Proactive suggestions | ✅ | ✅ | ✅ | Shared `ProactiveEngine` / `DecisionEngine` |
| Quiet hours / presence gating | ✅ | ✅ | ✅ | Shared `DecisionEngine` |
| **Reminders / Alarms** | | | | |
| Set reminder (voice) | ✅ | ✅ | ✅ | Shared `ReminderTool` |
| Set alarm (voice) | ✅ | ✅ | ✅ | Shared tool |
| **Camera / Vision** | | | | |
| Camera view / scene analysis | ✅ | ✅ | ✅ | Shared `AnalyzeCameraViewTool` |
| Screenshot + describe | ✅ | ✅ | ✅ | Shared `ScreenshotTool` |
| **Maps / Navigation** | | | | |
| Navigate to address (voice) | ✅ | ✅ | ✅ | Shared `NavigationTool` |
| Start navigation in Maps | ✅ | ✅ | ✅ | Shared `AppControlService.startNavigation()` |
| **Timers** | | | | |
| Set timer (voice) | ✅ | ✅ | ✅ | Shared tool |
| **Performance** | | | | |
| Calendar query off-main thread | ✅ | ✅ | ✅ | `produceState` + `withContext(Dispatchers.IO)` |
| File query off-main thread | ✅ | ✅ | ✅ | `viewModelScope.launch(Dispatchers.IO)` |
| Draft auto-save debounced | 🚫 | ✅ | ✅ | `viewModelScope.launch` on every mutation |
| ViewModel survives rotation | ✅ | ✅ | ✅ | All tablet panels use `AndroidViewModel` |

---

## Tablet-Only Features (no phone equivalent)

These features exist only on the tablet shell and represent genuine workstation additions:

| Feature | Panel | Description |
|---------|-------|-------------|
| Split-pane layout | `TabletShell` | Persistent sidebar + detail pane visible simultaneously |
| Action plan timeline | `TabletActionPlanPanel` | Visual step-by-step execution display |
| File context system | `TabletFileTrayPanel` | Tap-to-select file persists globally across panels |
| Email compose state | `TabletEmailPanel` | Full To/CC/BCC/Subject/Body with draft recovery |
| Email attachments | `TabletEmailPanel` | Attach files from active file context |
| Global action buttons | `TabletAppControlPanel` | One-tap Home / Back / Recents / Screenshot |
| Live foreground app | `TabletAppControlPanel` | Shows current foreground package with live polling |
| Recent apps history | `TabletAppControlPanel` | Rolling list of 6 recently-seen apps |
| Accessibility diagnostics | `TabletAppControlPanel` | Status badge + deep-link CTA when not connected |
| Home Assistant quick tiles | `TabletHomeAssistantPanel` | 2-col command grid for common HA actions |
| Calendar event browser | `TabletCalendarPanel` | Upcoming 7-day visual event list |

---

## Known Gaps / Roadmap

| Gap | Priority | Notes |
|-----|----------|-------|
| Contacts integration in email To: field | P2 | Autocomplete from `ContactsContract` |
| Notification panel | P2 | Display recent notifications, dismiss, reply |
| Draft for SMS compose | P3 | Mirror email draft pattern for Messages |
| File search / filter | P3 | Name search bar in `TabletFileTrayPanel` |
| App close (force-stop) | P2 | Requires `ActivityManager.forceStopPackage` (system permission) or `GLOBAL_ACTION_HOME` + recents swipe |
| GA4-style event tracking for tablet | P3 | Tablet usage events |
| Tablet-specific voice hints engine | P3 | Contextual hints based on active panel |
