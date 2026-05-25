using Jarvis.Core.Awareness;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Snapshot;

namespace Jarvis.Perception.Presence;

/// <summary>
/// Infers <see cref="PresenceMode"/> from focus metrics and recent app usage.
/// When a user override is active via <see cref="SetMode"/>, auto-detection is suspended
/// until <see cref="ClearOverride"/> is called.
/// Thread-safe: all state mutations are behind <c>lock (_gate)</c>.
/// </summary>
public sealed class PresenceModeManager : IPresenceModeManager
{
    private readonly IFocusSessionTracker _focusTracker;
    private readonly IAppUsageTracker _usageTracker;
    private readonly Func<AwarenessSettings> _settings;
    private readonly object _gate = new();

    private PresenceMode _current = PresenceMode.Work;
    private bool _isUserOverride;
    private PresenceMode _overrideMode;
    private bool _started;

    public PresenceModeManager(
        IFocusSessionTracker focusTracker,
        IAppUsageTracker usageTracker,
        Func<AwarenessSettings> settings)
    {
        _focusTracker = focusTracker;
        _usageTracker = usageTracker;
        _settings = settings;
    }

    public PresenceMode Current => _current;
    public bool IsUserOverride => _isUserOverride;
    public event EventHandler<PresenceMode>? ModeChanged;

    public Task StartAsync(CancellationToken ct = default)
    {
        if (_started) return Task.CompletedTask;
        _focusTracker.MetricsChanged += OnMetricsChanged;
        _usageTracker.EntryAdded += OnEntryAdded;
        _started = true;
        Recompute();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        if (!_started) return Task.CompletedTask;
        _focusTracker.MetricsChanged -= OnMetricsChanged;
        _usageTracker.EntryAdded -= OnEntryAdded;
        _started = false;
        return Task.CompletedTask;
    }

    public void SetMode(PresenceMode mode)
    {
        PresenceMode? changed = null;
        lock (_gate)
        {
            _isUserOverride = true;
            _overrideMode = mode;
            if (_current != mode)
            {
                _current = mode;
                changed = mode;
            }
        }
        if (changed.HasValue)
            ModeChanged?.Invoke(this, changed.Value);
    }

    public void ClearOverride()
    {
        lock (_gate)
        {
            _isUserOverride = false;
        }
        Recompute();
    }

    private void OnMetricsChanged(object? sender, FocusMetrics _) => Recompute();
    private void OnEntryAdded(object? sender, AppUsageEntry _) => Recompute();

    private void Recompute()
    {
        PresenceMode? changed = null;
        lock (_gate)
        {
            if (_isUserOverride) return;

            var inferred = Infer();
            if (inferred != _current)
            {
                _current = inferred;
                changed = inferred;
            }
        }
        if (changed.HasValue)
            ModeChanged?.Invoke(this, changed.Value);
    }

    private PresenceMode Infer()
    {
        var focus = _focusTracker.Current;
        var recent = _usageTracker.GetRecent(10);
        var settings = _settings();

        // Gaming: any recent entry matches a gaming process
        foreach (var entry in recent)
        {
            if (WorkflowCategorizer.GamingProcesses.Contains(entry.ProcessName))
                return PresenceMode.Gaming;
        }

        // Presentation: fullscreen-ish heuristic — primary workflow Unknown, low switches, sustained duration
        if (focus.PrimaryWorkflow == WorkflowCategory.Unknown
            && focus.AppSwitchesLast10Min <= 1
            && focus.FocusDuration.TotalMinutes >= 5)
            return PresenceMode.Presentation;

        // Developer mode
        if (settings.DevMode)
            return PresenceMode.Developer;

        // Focus / DeepWork
        if (focus.State is FocusState.DeepWork or FocusState.Focused)
            return PresenceMode.Focus;

        // Casual
        if (focus.PrimaryWorkflow is WorkflowCategory.Media or WorkflowCategory.Browsing or WorkflowCategory.Shopping)
            return PresenceMode.Casual;

        return PresenceMode.Work;
    }
}
