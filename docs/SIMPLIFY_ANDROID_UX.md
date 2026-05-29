# Simplify Android UX

Android must become a **polished connector/client** for the Mac brain — not an
engineering console. The Mac brain owns intelligence, orchestration, memory,
model/provider/prompt/agent settings, routing, and deep diagnostics. Android keeps
phone‑native capability + a tiny, appliance‑like UI.

Evidence base: `Android/app/src/main/java/com/jarvis/assistant/ui/`.

## Counts (current)
- **Settings sub‑screens:** ~45 (`ui/settings/screens/*.kt`).
- **Settings categories/routes wired in the nav graph:** ~37 (`ui/SettingsScreen.kt:56-259`, `ui/settings/SettingsCategory.kt`).
- **Root settings sections:** 6 — Voice, Conversation, Intelligence, Mac Integration, About, **Developer & Diagnostics** (`ui/settings/SettingsSection.kt:34-54`).
- **Diagnostics / developer / experimental screens:** 12 — Connection, Voice, Vision, AppControl, Session, Trust, MacBrain, Messaging diagnostics; "Diagnostics Dashboard" (`LocalDiagnosticsScreen`); `SpeechLatencyScreen`; `DeveloperDiagnosticsScreen` (hub); `ExperimentalFlagsSettingsScreen`.
- **Duplicate Mac‑connection screens:** 5 — `MacIntegrationScreen`, `MacBrainSettingsScreen`, `MacBrainDiagnosticsScreen`, `MacBrain*`/`BrainGateway`/`MacBridge` categories (`ui/SettingsScreen.kt:230-259`).
- **Tablet shell** exposes a Diagnostics rail + panel (`ui/tablet/TabletShell.kt:41,166`, `TabletDiagnosticsPanel`, `TabletActionPlanPanel`) — a desktop‑style dashboard at odds with the connector‑client direction.
- **Screens with no daily‑user purpose:** the 12 diagnostics/dev screens + duplicate Mac screens ≈ **17**.

## Target normal UI (all that should remain in daily navigation)
Main assistant screen (+ listening/speaking orb) → `ui/MainScreen.kt`; Mac connection status (ONE screen); Permissions status (ONE screen); Start/stop (on main); minimal Voice/mic; device identity (in Mac connection); **one** Troubleshooting entry. Optional, collapsed: Appearance (theme), phone‑native integration toggles the user truly needs.

## Classification table

Legend — **Keep** / **Move to Mac** / **Emergency** (one obscure confirm‑gated route) / **Delete**.

| Name | Location | Class | Reason | Action / Replacement | Issue |
|---|---|---|---|---|---|
| MainScreen | `ui/MainScreen.kt` | Keep | The product | — | — |
| ConversationPanel | `ui/ConversationPanel.kt` | Keep | Transcript on main | — | — |
| Permission rationale/status | `ui/MainActivity.kt:176`; `ui/settings/PermissionUtils.kt` | Keep | Essential | Consolidate to one "Permissions" status screen | Simplify settings (#5) |
| Mac connection (consolidated) | from `MacIntegrationScreen.kt` | Keep | Core: connect to brain | Keep ONE; show pairing + status + device id | Remove duplicates (#6) |
| VoiceSettingsScreen (minimal) | `ui/settings/screens/VoiceSettingsScreen.kt` | Keep | Voice pick/mic | Trim to voice + mic only; move STT/TTS internals to Mac | Simplify settings (#5) |
| AboutHelp / FAQ | `AboutHelpSettingsScreen.kt`, `FaqSettingsScreen.kt` | Keep | About + help | Merge into ONE About/Help; FAQ folds in | Remove duplicates (#6) |
| **Troubleshooting (NEW)** | new `ui/settings/screens/TroubleshootingScreen.kt` | Keep | Replaces all diagnostics | 5 entries (below) + bundle export | Troubleshooting flow (#2) |
| Appearance (theme) | `AppearanceSettingsScreen.kt` | Keep | Simple user pref | Keep (small) | — |
| MacCameraViewerScreen | `ui/camera/MacCameraViewerScreen.kt` | Keep | Cross‑device feature | Keep | — |
| ConnectionDiagnosticsScreen | `screens/ConnectionDiagnosticsScreen.kt` | Move→Troubleshooting | Connection debug | Fold into "Connection problem" | Remove diag from nav (#1) |
| LocalDiagnosticsScreen ("Diagnostics Dashboard") | `screens/LocalDiagnosticsScreen.kt` | Move to Mac | Engineering dashboard | Emit health events to Mac; remove screen | Move diag to Mac (#3) |
| VoiceDiagnosticsScreen | `screens/VoiceDiagnosticsScreen.kt` | Move to Mac | STT/VAD internals | Remove; Mac console | Move diag to Mac (#3) |
| VisionDiagnosticsScreen | `screens/VisionDiagnosticsScreen.kt` | Move to Mac | Vision internals | Remove; Mac console | Move diag to Mac (#3) |
| AppControlDiagnosticsScreen | `screens/AppControlDiagnosticsScreen.kt` | Move to Mac | Routing/app debug | Remove; Mac console | Move diag to Mac (#3) |
| SessionDiagnosticsScreen | `screens/SessionDiagnosticsScreen.kt` | Move to Mac | Session internals | Remove; Mac console | Move diag to Mac (#3) |
| TrustDiagnosticsScreen | `screens/TrustDiagnosticsScreen.kt` | Move to Mac | Autonomy internals | Remove; Mac console | Move diag to Mac (#3) |
| MacBrainDiagnosticsScreen | `screens/MacBrainDiagnosticsScreen.kt` | Move to Mac | Brain routing internals | Remove; Mac console | Move diag to Mac (#3) |
| MessagingDiagnosticsScreen | `screens/MessagingDiagnosticsScreen.kt` | Move to Mac | Notification intel debug | Remove; Mac console | Move diag to Mac (#3) |
| SpeechLatencyScreen (latency graphs) | `screens/SpeechLatencyScreen.kt` | Move to Mac | Latency graphs | Remove; Mac console (timings in bundle) | Move diag to Mac (#3) |
| DeveloperDiagnosticsScreen (hub) | `screens/DeveloperDiagnosticsScreen.kt` | Emergency | Dev hub listing all diag | Replace with obscure confirm‑gated export | Emergency route (#2) |
| ExperimentalFlagsSettingsScreen | `screens/ExperimentalFlagsSettingsScreen.kt` | Emergency | Experimental switches | Behind emergency route; default flags fixed | Emergency route (#2) |
| AdvancedSettingsScreen (LLM provider/fallback/model/keys/max‑tokens) | `screens/AdvancedSettingsScreen.kt:54-196` | Move to Mac | Model/provider/keys are brain‑owned | Remove from Android; Mac owns model config | Move diag to Mac (#3) |
| PersonalitySettingsScreen | `screens/PersonalitySettingsScreen.kt` | Move to Mac | Prompt/persona = brain | Remove; Mac owns | Move diag to Mac (#3) |
| AmbientIntelligenceSettingsScreen | `screens/AmbientIntelligenceSettingsScreen.kt` | Move to Mac | Intelligence behaviour | Remove; Mac owns | Move diag to Mac (#3) |
| ProactivitySettingsScreen | `screens/ProactivitySettingsScreen.kt` | Move to Mac | Proactive policy = brain | Remove; Mac owns | Move diag to Mac (#3) |
| MemorySettingsScreen | `screens/MemorySettingsScreen.kt` | Move to Mac | Memory internals | Keep only "erase my data"; move internals to Mac | Move diag to Mac (#3) |
| TrustAutonomySettingsScreen | `screens/TrustAutonomySettingsScreen.kt` | Move to Mac | Autonomy policy = brain | Remove; Mac owns | Move diag to Mac (#3) |
| ResponsePreferencesSettingsScreen | `screens/ResponsePreferencesSettingsScreen.kt` | Move to Mac | Response shaping = brain | Remove; Mac owns | Move diag to Mac (#3) |
| RoutinesSettingsScreen | `screens/RoutinesSettingsScreen.kt` | Move to Mac | Routine synth = brain | Remove; Mac owns | Move diag to Mac (#3) |
| Phrases (category) | `ui/SettingsScreen.kt:187` | Move to Mac | Phrase/command tuning = brain | Remove; Mac owns | Move diag to Mac (#3) |
| ConversationSettingsScreen | `screens/ConversationSettingsScreen.kt` | Move to Mac | Conversation behaviour = brain | Remove (keep nothing user‑facing) | Move diag to Mac (#3) |
| VisionSettingsScreen | `screens/VisionSettingsScreen.kt` | Move to Mac | Vision config = brain | Keep only a camera on/off if needed | Move diag to Mac (#3) |
| HomeAssistantSettingsScreen | `screens/HomeAssistantSettingsScreen.kt` | Move to Mac | Brain orchestrates HA | Move config to Mac; Android reads entities from brain | Move diag to Mac (#3) |
| TodoistSettingsScreen | `screens/TodoistSettingsScreen.kt` | Move to Mac | Integration token = brain | Move to Mac | Move diag to Mac (#3) |
| MacBrainSettingsScreen | `screens/MacBrainSettingsScreen.kt` | Delete | Duplicate Mac‑connection UI | Collapse into the one Mac connection screen | Remove duplicates (#6) |
| BrainGateway (category) | `ui/SettingsScreen.kt:247` | Delete | Duplicate Mac‑connection UI | Collapse | Remove duplicates (#6) |
| MacBridge (category) | `ui/SettingsScreen.kt:253` | Delete | Duplicate Mac‑connection UI | Collapse | Remove duplicates (#6) |
| MacBrain (category) | `ui/SettingsScreen.kt:259` | Delete | Duplicate Mac‑connection UI | Collapse | Remove duplicates (#6) |
| WearablesSettingsScreen | `screens/WearablesSettingsScreen.kt` | Delete | Maintainer‑PAT/stub‑gated; not daily | Remove from nav (feature‑flag if revived) | Hide engineering routes (#7) |
| ContactAliasesSettingsScreen | `screens/ContactAliasesSettingsScreen.kt` | Move to Mac | Correction memory = brain | Move; Android still resolves contacts | Move diag to Mac (#3) |
| ActionsAppsSettingsScreen | `screens/ActionsAppsSettingsScreen.kt` | Keep (min)/Move | App‑launch aliases | Auto‑learn; minimise UI | Simplify settings (#5) |
| AppControlSettingsScreen | `screens/AppControlSettingsScreen.kt` | Keep (min) | Accessibility app‑control toggle | Keep minimal (it's a permission) | Simplify settings (#5) |
| SavedLocationsSettingsScreen | `screens/SavedLocationsSettingsScreen.kt` | Keep (min) | Home/work for "travel home" | Keep minimal | Simplify settings (#5) |
| CalendarSettingsScreen | `screens/CalendarSettingsScreen.kt` | Keep (min) | Phone calendar source/permission | Keep minimal (perm + source) | Simplify settings (#5) |
| NotificationsSettingsScreen | `screens/NotificationsSettingsScreen.kt` | Keep (min) | Notification‑access permission | Fold into Permissions | Simplify settings (#5) |
| Tablet Diagnostics rail + panel | `ui/tablet/TabletShell.kt:41,166`; `TabletDiagnosticsPanel` | Delete | Engineering dashboard on tablet | Remove rail item + panel | Remove diag from nav (#1) |
| Tablet ActionPlan (recent routes/latency) | `ui/tablet/TabletActionPlanPanel.kt:265-296` | Move to Mac | Routing/latency debug | Remove latency rows | Move diag to Mac (#3) |
| Root "Developer & Diagnostics" section | `ui/settings/SettingsSection.kt:54` | Delete | Engineering section in normal settings | Remove section entirely | Hide engineering routes (#7) |
| Root "Intelligence" section | `ui/settings/SettingsSection.kt:42` | Move to Mac | Brain behaviour grouping | Remove section (its screens move to Mac) | Hide engineering routes (#7) |
| `developerModeEnabled` toggle | `ui/SettingsViewModel.kt:134-139` | Emergency | Discoverable dev toggle | Replace with obscure emergency gesture | Emergency route (#2) |

## One troubleshooting flow (replaces all diagnostics)
`TroubleshootingScreen` with 5 entries, each a guided check reusing existing instrumentation:
- **Connection problem** → Mac‑brain connection state from `remote/macbrain/MacBrainConnectionManager.sharedStatus` + `MacBrainDiagnosticsSnapshot`; offers re‑pair.
- **Microphone problem** → mic permission + `audio/MicInputProfiler` route + `reliability/ListenerDiagnostics` (listening/restart state).
- **Permission problem** → permission matrix from `ui/settings/PermissionUtils.kt`; deep‑link to App Settings.
- **Command failed** → recent failures from `diagnostics/LocalRouteDiagnostics` (route + outcome + latency) + `reliability/ListenerDiagnostics.remoteReplyTimeouts`.
- **Export diagnostic bundle** → see below.

## Diagnostic bundle (sanitised)
`DiagnosticBundleBuilder` produces a single shareable file containing:
- App version/build (`BuildConfig`), device/OS info.
- Permission state (`PermissionUtils`).
- Mac‑brain connection state (`MacBrainDiagnosticsSnapshot`).
- Recent command failures (`diagnostics/LocalRouteDiagnostics` entries — tool, outcome, **no transcript bodies**).
- Recent crash/error summaries (`reporting/github/CrashReportBuilder` output, redacted).
- Recent latency timings (`gateway/LatencyTracker` / `SpeechTurnStore` — durations only).
- **Sanitised logs only** — no message/contact/calendar/location content unless the user explicitly opts in.

## Architecture
Keep instrumentation internally (`LocalRouteDiagnostics`, `ListenerDiagnostics`, `LatencyTracker`, `SpeechTurnStore`). Remove the diagnostics **UI**. Android emits structured health events to the Mac brain (new `health.event` frame) and the **Mac** provides the detailed diagnostics console. Android stays simple, fast, quiet.

## Target navigation graph
Phone `AppNavHost` (`ui/MainActivity.kt:161`): `main` → `settings`. Settings root shows only: **Mac connection**, **Voice**, **Permissions**, **Appearance**, **Troubleshooting**, **About/Help**. Remove from the graph all routes at `ui/SettingsScreen.kt:65-259` except those six; delete the `DeveloperDiagnostics`/`ExperimentalFlags`/`*Diagnostics`/`SpeechLatency`/`BrainGateway`/`MacBridge`/`MacBrain`/Advanced/Personality/Ambient/Proactivity/Memory(internals)/TrustAutonomy/ResponsePreferences/Routines/Phrases/Conversation/Vision routes (move behaviour to Mac). Tablet: remove the Diagnostics rail item (`TabletShell.kt:41`).

## Acceptance
A normal user understands every visible screen with no technical knowledge; one clear main screen; minimal settings; no diagnostics in normal product; dev tools invisible in daily use; all removed diagnostics still available via the bundle/structured logs; no loss of phone‑command capability; no latency increase; fewer screens/toggles/decisions.
