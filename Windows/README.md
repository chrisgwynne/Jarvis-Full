# Jarvis Windows — Pebble Runtime (Foundation)

Ambient desktop assistant. WPF + WebView2 host with a transparent, click-through,
always-on-top overlay that follows the cursor. This commit ships the **foundation only**
— Phase 1 visuals + Phase 2 awareness baseline + settings/diagnostics scaffolding.

## Architecture

```
Jarvis.App            WPF host (overlay window, WebView2, cursor follower, DI bootstrap)
├── web/              Embedded pebble renderer (HTML/CSS/JS — animations live here)
├── Overlay/          CursorFollower, PebbleBridge (.NET → WebView2 state push)
└── Interop/          Win32 P/Invoke (overlay styles, cursor)

Jarvis.Core           No-deps domain layer (state machine, abstractions, settings shape)
├── State/            PebbleStateMachine, inputs snapshot, transition events
├── Awareness/        IDesktopAwarenessService, DesktopSnapshot
├── Diagnostics/      IDiagnostics
└── Settings/         IJarvisSettingsStore + record-based settings tree

Jarvis.DesktopAwareness  Win32-backed awareness service (foreground app, idle, window rect)
Jarvis.Settings          File-backed JsonSettingsStore (atomic writes, corrupt-file recovery)
Jarvis.Diagnostics       In-process ring buffer + PerformanceSampler (CPU / RAM / threads)

tests/Jarvis.Core.Tests  xUnit coverage for state machine, settings, diagnostics
```

### Design decisions

- **WPF + WebView2** for the overlay. WPF gives us a per-pixel-alpha transparent
  top-level window with full Win32 access; WebView2 gives us GPU-composited CSS/SVG
  animations without bringing in WinUI/Composition API complexity.
- **State machine is pure**. No timers, no I/O. Callers push immutable
  `PebbleStateInputs` snapshots; the machine resolves a single state via a priority
  ladder (`Error > Alert > Muted > Speaking > Listening > Working > Thinking > Focused > Idle`).
  This keeps it trivially testable and threadsafe.
- **Cursor following uses `CompositionTarget.Rendering`**, not a timer. The hook
  fires once per WPF compositor frame, synced to the display, so motion stays smooth
  without us scheduling our own ticks. Easing factor is per-frame proportional, so
  the trail "feels" consistent across refresh rates.
- **Awareness service polls at 250 ms**. Win32 has no cheap notification for
  foreground-title changes; polling at this cadence costs <0.1% CPU and is below
  human perception. The service only fires `SnapshotChanged` on a meaningful diff
  (hwnd, title, or active/idle transition).
- **State sync is one-way, JSON over `PostWebMessageAsJson`**. Renderer reacts via
  a single CSS class swap on `#pebble`. No DOM rebuild per state.
- **Settings persisted to `%APPDATA%\Jarvis\settings.json`** with atomic temp+rename
  writes. A corrupt file is quarantined (`.corrupt.<unix-ts>`) and replaced with
  defaults rather than crashing on launch.

## Pebble states (and their visual treatment)

| State | Trigger | Animation |
|-------|---------|-----------|
| Idle | no signals | breathing core |
| Listening | mic open / listening flag | halo pulse + core swell |
| Thinking | interrupted | orbiting particles + breathing |
| Speaking | TTS active | expanding ripple ring |
| Working | automation or active task | core bob + soft halo |
| Focused | foreground app + user active | gentle breathing |
| Alert | `HasAlert` | warm-tinted pulse |
| Muted | `Muted` | desaturated, static |
| Error | `HasError` | red-tinted blink |

## Build & run

```powershell
dotnet restore
dotnet build Jarvis.sln -c Release
dotnet run --project src/Jarvis.App
```

WebView2 Runtime is required (preinstalled on Windows 11). The `web/` folder is
exposed to the WebView via `SetVirtualHostNameToFolderMapping("pebble.local", ...)`,
so the renderer can be opened standalone in a browser for design iteration —
it self-cycles through states when no host bridge is detected.

## Performance targets

- Overlay refresh: matches display (60–240 Hz), bound by WPF compositor.
- Awareness poll: 250 ms cadence, <1% CPU on idle desktop.
- Idle-state pebble: ~1–2% CPU (animation), ~80 MB private working set (WebView2 baseline).
- All animation work is `transform`/`opacity` only — compositor-friendly, no layout invalidation.

## What's intentionally NOT here yet

Deferred to later phases per scope:

- OCR / screenshot pipeline
- Foreground semantic resolver (per-app intent reinterpretation)
- DesktopSemanticLayer (UI Automation tree, accessibility consolidation)
- Region capture (Alt+drag)
- Browser extension + IDE integrations
- AutomationExecutor
- Passive awareness heuristics
- "Where do I click?" guidance overlays
- Settings UI window (settings *model* is in place; UI is later)
- AI-driven proactivity

Hooks for each exist via the `IDesktopAwarenessService`, `IDiagnostics`, and
`PebbleStateMachine` seams.

## Known limitations / scalability notes

- **Active monitor enumeration is stubbed** (`ActiveMonitorIndex = 0`). Multi-monitor
  awareness needs `EnumDisplayMonitors` — straightforward, deferred for scope.
- **Awareness service runs on a single polling loop**. For richer signals
  (selection text, clipboard, browser URL) we'll want event-driven sources
  (WinEvents `EVENT_SYSTEM_FOREGROUND`, clipboard listener via `AddClipboardFormatListener`).
  Migrate incrementally without changing the public seam.
- **PebbleBridge is one-way**. When the renderer needs to send signals back
  (hover, click on the pebble), wire `CoreWebView2.WebMessageReceived` symmetrically.
- **No global hotkeys yet**. Settings model defines `PushToTalk` etc., but
  `RegisterHotKey` wiring lives with input/voice work (later phase).
- **WPF + WebView2 memory floor** is ~80 MB. If we ever need to drop under that,
  the cleanest path is replacing the renderer with a `DirectComposition` + SkiaSharp
  surface — same `PebbleBridge` seam, different sink.
