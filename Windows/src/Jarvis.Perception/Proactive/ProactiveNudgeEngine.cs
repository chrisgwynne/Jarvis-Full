using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Proactive;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Proactive;

/// <summary>
/// Watches <see cref="IFocusSessionTracker.MetricsChanged"/> and fires sparse, calm
/// nudges when focus milestones are reached or distraction loops are detected.
/// Respects <see cref="ProactivitySettings"/> suppression rules and deduplicates
/// within the configured <see cref="ProactivitySettings.MinGapMinutes"/> window.
/// </summary>
public sealed class ProactiveNudgeEngine : IProactiveNudgeEngine
{
    private const int MaxLastFiredEntries = 20;

    private readonly IFocusSessionTracker _focusTracker;
    private readonly IPresenceModeManager _presenceManager;
    private readonly Func<ProactivitySettings> _settings;
    private readonly object _gate = new();

    // Dedup: key → last fired at
    private readonly Dictionary<string, DateTimeOffset> _lastFired = new(MaxLastFiredEntries);

    // Crossing detection: last FocusDuration to detect threshold crosses
    private TimeSpan _lastFocusDuration = TimeSpan.Zero;
    private bool _started;

    public ProactiveNudgeEngine(
        IFocusSessionTracker focusTracker,
        IPresenceModeManager presenceManager,
        Func<ProactivitySettings> settings)
    {
        _focusTracker = focusTracker;
        _presenceManager = presenceManager;
        _settings = settings;
    }

    public event EventHandler<ProactiveNudge>? NudgeReady;

    public Task StartAsync(CancellationToken ct = default)
    {
        if (_started) return Task.CompletedTask;
        _focusTracker.MetricsChanged += OnMetricsChanged;
        _started = true;
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        if (!_started) return Task.CompletedTask;
        _focusTracker.MetricsChanged -= OnMetricsChanged;
        _started = false;
        return Task.CompletedTask;
    }

    private void OnMetricsChanged(object? sender, FocusMetrics metrics)
    {
        var settings = _settings();
        if (!settings.Enabled) return;

        var mode = _presenceManager.Current;

        // Global suppression
        if (mode is PresenceMode.Gaming or PresenceMode.Presentation or PresenceMode.Silent)
            return;

        var now = DateTimeOffset.UtcNow;
        TimeSpan prevDuration;

        lock (_gate)
        {
            prevDuration = _lastFocusDuration;
            _lastFocusDuration = metrics.FocusDuration;
        }

        // Distraction loop alert
        if (settings.DistractionAlerts
            && metrics.AppSwitchesLast10Min >= 15
            && !(settings.SuppressDuringFocus && mode == PresenceMode.Focus))
        {
            TryFire("distraction_loop", settings,
                $"You've switched apps {metrics.AppSwitchesLast10Min} times in the last 10 minutes.", now);
        }

        // Focus milestones (crossing detection)
        if (settings.FocusMilestones)
        {
            // 30-min milestone
            if (metrics.FocusDuration.TotalMinutes >= 30
                && prevDuration.TotalMinutes < 30
                && metrics.State is FocusState.Focused or FocusState.DeepWork)
            {
                TryFire("focus_30min", settings, "Nice focus session — 30 minutes in.", now);
            }

            // 90-min milestone
            if (metrics.FocusDuration.TotalMinutes >= 90 && prevDuration.TotalMinutes < 90)
            {
                TryFire("focus_90min", settings, "Deep work mode — 90 minutes uninterrupted.", now);
            }

            // 2-hour milestone
            if (metrics.FocusDuration.TotalMinutes >= 120 && prevDuration.TotalMinutes < 120)
            {
                TryFire("focus_milestone", settings, "Two hours of focused work. Consider a break.", now);
            }
        }
    }

    private void TryFire(string key, ProactivitySettings settings, string message, DateTimeOffset now)
    {
        ProactiveNudge? nudge = null;
        lock (_gate)
        {
            if (_lastFired.TryGetValue(key, out var lastAt))
            {
                if ((now - lastAt).TotalMinutes < settings.MinGapMinutes)
                    return;
            }

            _lastFired[key] = now;

            // Trim oldest if overflow
            if (_lastFired.Count > MaxLastFiredEntries)
            {
                var oldest = _lastFired.MinBy(kv => kv.Value).Key;
                _lastFired.Remove(oldest);
            }

            nudge = new ProactiveNudge(key, message, now);
        }

        if (nudge is not null)
            NudgeReady?.Invoke(this, nudge);
    }
}
