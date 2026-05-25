# Windows Context Engine

## Architecture

The context pipeline flows from raw Win32 observations to a structured payload sent to the Mac brain:

```
Win32 foreground-window events
        │
        ▼
DesktopAwarenessService (polls at 250 ms)
        │
        ▼
AppUsageTracker (ring buffer, 20 entries)
        │
        ├──► FocusSessionTracker (10-min sliding window, max 50 entries)
        │
        ├──► PresenceModeManager (auto-inference or user override)
        │
        ▼
WindowsContextEngine
        │
        ├── PerceptionService (SemanticSnapshot)
        ├── AppUsageTracker (PrivacySafeTimeline)
        ├── FocusSessionTracker (FocusMetrics)
        └── PresenceModeManager (PresenceMode)
                │
                ▼
        IWindowsContextSnapshotBuilder.Build(...)
                │
                ▼
        WindowsContextSnapshot (with SHA1 hash)
                │
                ▼
        SidecarContextPublisher
                │
                ▼
        ContextPayload (JSON → Mac Brain via WebSocket)
```

## New Types

### FocusMetrics

Records continuous focus session data:

| Field | Type | Description |
|---|---|---|
| `SessionStartedAt` | `DateTimeOffset` | When the current session began |
| `FocusDuration` | `TimeSpan` | Continuous focus time since `SessionStartedAt` |
| `AppSwitchesLast10Min` | `int` | Count of app switch entries in last 10 minutes |
| `DistractionCount` | `int` | Switches to non-work apps in current session |
| `ProductivityScore` | `double` | 0..1 composite score |
| `State` | `FocusState` | Idle / Distracted / Working / Focused / DeepWork |
| `PrimaryApp` | `string?` | Most frequent process in last 20 entries |
| `PrimaryWorkflow` | `WorkflowCategory` | Most frequent workflow in last 20 entries |

### PresenceMode

Seven modes for controlling proactivity and bridge routing:

- `Work` — standard desk work
- `Focus` — deep work detected, reduced proactivity
- `Casual` — browsing or media
- `Gaming` — gaming process in foreground, suppress all proactive speech
- `Presentation` — fullscreen sustained session, suppress proactivity
- `Silent` — user-set override, zero proactivity
- `Developer` — debug mode, verbose diagnostics

### WorkSession

Immutable record of one completed work session, persisted to sessions.jsonl:

| Field | Type | Description |
|---|---|---|
| `Id` | `string` | GUID |
| `StartedAt` | `DateTimeOffset` | Session start time |
| `EndedAt` | `DateTimeOffset` | Session end time |
| `PrimaryWorkflow` | `WorkflowCategory` | Dominant workflow |
| `PrimaryApp` | `string?` | Dominant application |
| `TotalFocusDuration` | `TimeSpan` | Total focused time |
| `TotalAppSwitches` | `int` | Total app switches |
| `PeakProductivityScore` | `double` | Peak productivity score |
| `TimelineSummary` | `string` | Compact timeline string |

## Lifecycle

### StartAsync / StopAsync

```
App.OnStartup:
  1. awareness.StartAsync()
  2. focusTracker.StartAsync()        → subscribes to AppUsageTracker.EntryAdded
  3. presenceManager.StartAsync()     → subscribes to focusTracker.MetricsChanged + AppUsageTracker.EntryAdded
  4. nudgeEngine.StartAsync()         → subscribes to focusTracker.MetricsChanged
  5. contextPublisher.StartAsync()
  6. windowsContextEngine.StartAsync() → subscribes to PerceptionService.Changed,
                                          AppUsageTracker.EntryAdded,
                                          focusTracker.MetricsChanged,
                                          presenceManager.ModeChanged
```

On `StopAsync`, all event subscriptions are detached in reverse order.

## Hash-based dedup

`WindowsContextSnapshotBuilder` computes a SHA1 over:
- `SemanticSnapshot.Hash`
- Recent distinct process names (comma-joined)
- `PrivacySafeTimeline.ToCompactSummary()`
- `FocusDuration.TotalMinutes` (formatted to nearest minute)
- `PresenceMode.ToString()`

`WindowsContextEngine` only fires `ContextChanged` and pushes a new frame when the hash changes. This prevents redundant Mac brain updates.

## Event subscription model

All components follow the same pattern:
- `StartAsync()` attaches event handlers
- `StopAsync()` detaches them
- Events are fired from background threads; WPF consumers must `Dispatcher.BeginInvoke`

## SidecarContextPublisher Enrichment Path

`SidecarContextPublisher` builds the base `ContextPayload` from the `ConversationContext` produced by `IContextBudgeter` (which applies redaction and truncation). It then enriches the payload with real-time context-engine data:

```
SidecarContextPublisher.PublishCurrentAsync()
  │
  ├── IConversationContextBuilder.Build()   → base ConversationContext (redacted)
  ├── IContextBudgeter.Budget()             → compact form with SnapshotHash
  │
  ├── [Privacy gate] PrivacyMode == true → return (no frame sent)
  ├── [Privacy gate] TrackForegroundApp == false → skip enrichment
  │
  └── IWindowsContextEngine.Current         → enriched fields
        ├── FocusMinutes  = Focus.FocusDuration.TotalMinutes
        ├── PresenceMode  = PresenceMode.ToString()
        ├── ProductivityScore = Focus.ProductivityScore
        ├── AppSwitchesLast10Min = Focus.AppSwitchesLast10Min
        ├── RecentApps    = RecentProcessNames (null if empty)
        └── TimelineSummary = Timeline.ToCompactSummary()
```

The enrichment step is skipped entirely when:
- `SidecarSettings.PrivacyMode == true` (no frame sent at all)
- `AwarenessSettings.TrackForegroundApp == false` (frame sent, enriched fields are null)
- `IWindowsContextEngine` was not injected (no-op, enriched fields are null)

### DI Wiring

```csharp
services.AddSingleton<ISidecarContextPublisher>(sp => new SidecarContextPublisher(
    perception: sp.GetRequiredService<PerceptionService>(),
    builder: sp.GetRequiredService<IConversationContextBuilder>(),
    budgeter: sp.GetRequiredService<IContextBudgeter>(),
    bridge: sp.GetRequiredService<IMacBridgeCoordinator>(),
    settings: () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Sidecar,
    contextEngine: sp.GetService<IWindowsContextEngine>(),
    awarenessSettings: () => sp.GetRequiredService<IJarvisSettingsStore>().Current.Awareness));
```

## Privacy rules

- **Stored:** process names, workflow categories, dwell durations, focus metrics
- **Never stored:** raw window titles (unless they pass the sensitive-title filter), URLs from private browsing, transcript text, financial information
- **Sensitive title filter:** any title containing `incognito`, `private browsing`, `inprivate`, `password`, `bank`, `paypal`, `1password`, `bitwarden`, `keepass` is dropped — only process name + workflow are retained
- **Timeline entries** contain only `ProcessName`, `WorkflowCategory`, `Dwell`, and `StartedAt`
- **Session history** is bounded by 512 KB file cap with automatic oldest-20%-trimming
