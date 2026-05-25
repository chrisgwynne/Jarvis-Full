# Windows Phase 3 — Hardening Report

## Bugs Found and Fixed

### Bug 1 — SidecarContextPublisher did NOT send enriched fields [CRITICAL]

`SidecarContextPublisher` built `ContextPayload` from the old `SemanticSnapshot`-only path. The fields `focusMinutes`, `presenceMode`, `productivityScore`, `appSwitchesLast10Min`, `recentApps`, and `timelineSummary` were never populated.

**Fix:** `SidecarContextPublisher` now accepts `IWindowsContextEngine?` and `Func<AwarenessSettings>?` as optional constructor parameters. After building the base payload, it enriches from the context engine when present and when tracking is not disabled.

### Bug 2 — DashboardViewModel.ApplyContextSnapshot called off UI thread [CRITICAL]

`IWindowsContextEngine.ContextChanged` fires from the thread pool. `DashboardViewModel.Set<T>` raises `INotifyPropertyChanged` events inline, which in WPF must occur on the dispatcher thread.

**Fix:** In `App.xaml.cs`, the `ContextChanged` subscription now wraps the call:
```csharp
engine.ContextChanged += (_, snap) =>
    System.Windows.Application.Current.Dispatcher.BeginInvoke(() => vm.ApplyContextSnapshot(snap));
```

### Bug 3 — FocusSessionTracker used O(n) List.RemoveAt(0)

`_window` was a `List<AppUsageEntry>` using `RemoveAt(0)` for FIFO operations, which is O(n).

**Fix:** Replaced with `Queue<AppUsageEntry>`. All operations now use `Enqueue`, `Dequeue`, and `Peek`. `TakeLast(20)` replaced with `Skip(Math.Max(0, _window.Count - 20))`.

### Bug 4 — PresenceModeManager acquired lock on every usage event even when override was active

`OnEntryAdded` and `OnMetricsChanged` always called `Recompute()`, which then took the lock to check `_isUserOverride`.

**Fix:** Added `private volatile bool _isOverrideFast`. Both event handlers now check this flag before taking the lock. `SetMode()` sets it to `true`; `ClearOverride()` sets it to `false` before calling `Recompute()`.

### Bug 5 — SessionMemoryStore corrupt JSONL recovery

**Status:** Already fixed in the existing codebase. `ReadAllUnlocked()` already wraps per-line deserialization in a try-catch and skips bad lines. No further change needed.

### Bug 6 — Privacy: context tracking disabled did not stop enriched payload

When `AwarenessSettings.TrackForegroundApp == false`, the awareness service returns empty snapshots but the enriched ContextPayload would still send focus/presence data.

**Fix:** In `SidecarContextPublisher.PublishCurrentAsync()`, before enriching with context engine data, checks `_awarenessSettings?.Invoke().TrackForegroundApp ?? true`. If false, the enrichment block is skipped entirely.

---

## Wiring Verified

- `SidecarContextPublisher` DI registration updated to pass `IWindowsContextEngine` and `awarenessSettings`.
- `DashboardViewModel` DI wiring updated to use `Dispatcher.BeginInvoke`.
- `OnBridgeStatusChanged` in `App.xaml.cs` now also updates `DashboardViewModel.BridgeStatus`.
- `FocusSessionTracker`, `PresenceModeManager`, `ProactiveNudgeEngine`, `SessionMemoryStore` all receive `IDiagnostics` from DI.
- `ISessionMemoryStore` registration changed from `AddSingleton<ISessionMemoryStore, SessionMemoryStore>()` to explicit factory to pass diagnostics.

## Privacy Improvements

- **Sensitive-title filter expanded** in `AppUsageTracker` to include: `login`, `sign in`, `sign-in`, `signin`, `checkout`, `payment`, `billing`, `card`, `health`, `medical`, `insurance`, `tax`, `irs`, `hmrc`, `gov.uk`, `adult`, `nsfw`, `xxx` — in addition to the existing patterns.
- **TrackForegroundApp=false** now prevents enriched fields (focus, presence, timeline) from reaching the Mac bridge even if the context engine is running.
- **PrivacyMode=true** continues to suppress all context publishing (returns early, no frame sent).

## Reliability Improvements

- **Queue semantics** in `FocusSessionTracker` — FIFO sliding window now uses correct O(1) `Dequeue` instead of O(n) `RemoveAt(0)`.
- **Corrupt JSONL handling** — confirmed already present; no regression.
- **Dispatcher safety** — `DashboardViewModel` property changes now guaranteed to fire on the WPF dispatcher thread.
- **Override fast-path** in `PresenceModeManager` — `volatile bool _isOverrideFast` prevents unnecessary lock contention on every usage event when a user override is active.
- **Diagnostics** added to `FocusSessionTracker` (start/stop), `PresenceModeManager` (mode.inferred), `ProactiveNudgeEngine` (nudge.suppressed), `SessionMemoryStore` (memory.session.saved).

## H6 — DashboardWindow XAML cross-reference

All element names referenced in `DashboardWindow.Refresh()` are confirmed present in `DashboardWindow.xaml`:
- `StatusIndicator` ✓
- `PresenceModeText` ✓
- `BridgeStatusText` ✓
- `MacConnectionText` ✓
- `FocusDurationText` ✓
- `FocusStateText` ✓
- `ProductivityBar` ✓
- `ProductivityScoreText` ✓
- `WorkflowText` ✓
- `AppSwitchesText` ✓
- `SmartSuggestionText` ✓
- `TimelineSummaryText` ✓

`BridgeLatencyText` exists in XAML but is not set in `Refresh()` — this is intentional (left for future latency telemetry).

## H4 — DevMode Settings Panel

`SettingsWindow.xaml` has no `DevModePanel` element. Per implementation rules, no new XAML was created. This task is deferred.

## Remaining Risks

- `BridgeLatencyText` in the dashboard is never populated — needs a latency feed from `MacBridgeCoordinator.Status.LastRoundTripMs`.
- `SessionMemoryStore` uses a fixed file path (`%APPDATA%\Jarvis\sessions.jsonl`); in tests this writes to the real user profile. Consider injecting the path for testability.
- `PresenceModeManager.Infer()` returns `Presentation` when `PrimaryWorkflow == Unknown && AppSwitchesLast10Min <= 1 && FocusDuration >= 5min` — this heuristic may fire at startup before any usage data is available.
- No integration test covers the full pipeline from `AppUsageTracker` through `ContextEngine` to `SidecarContextPublisher`.

---

## Manual QA Checklist

### Startup
- [ ] App launches, all 4 new services start once
- [ ] Dashboard opens from tray, no crash
- [ ] Duplicate dashboard click focuses existing window

### Context
- [ ] Foreground app change updates workflow in dashboard
- [ ] Focus timer increments during uninterrupted work
- [ ] Gaming mode activates when Steam is open
- [ ] Mac bridge frame contains focusMinutes, presenceMode

### Privacy
- [ ] Sensitive titles (bank, incognito, checkout, login, medical) → TitleRedacted=true
- [ ] Disable TrackForegroundApp → enriched fields not sent
- [ ] PrivacyMode → no context frame sent at all

### Reliability
- [ ] Corrupt sessions.jsonl → loads cleanly (bad lines skipped)
- [ ] StartAsync called twice → only one subscription
- [ ] Shutdown → all services stop without exception
- [ ] User override set → incoming gaming entry does not override Silent mode

### UX
- [ ] SmartSuggestion shows for distraction loop
- [ ] Suggestion is absent for normal focused work
- [ ] Bridge status updates in dashboard live
- [ ] Focus milestone nudge fires once, not repeatedly
