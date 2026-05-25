using Jarvis.Core.Awareness;
using Jarvis.Core.Context;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Context;

/// <summary>
/// Subscribes to perception, app-usage, focus, and presence events and produces an
/// up-to-date <see cref="WindowsContextSnapshot"/> whenever something meaningful changes.
/// Fires <see cref="ContextChanged"/> only when the hash differs from the previous
/// snapshot — downstream consumers never need to dedup.
///
/// Respects <see cref="ContextEngineSettings.Enabled"/>: when false, the engine
/// keeps <see cref="Current"/> at an empty snapshot and suppresses all events.
/// </summary>
public sealed class WindowsContextEngine : IWindowsContextEngine
{
    private readonly PerceptionService _perception;
    private readonly IAppUsageTracker _usageTracker;
    private readonly IWindowsContextSnapshotBuilder _builder;
    private readonly IFocusSessionTracker _focusTracker;
    private readonly IPresenceModeManager _presenceManager;
    private readonly Func<ContextEngineSettings> _settings;
    private readonly IDiagnostics? _diagnostics;

    private readonly object _gate = new();
    private volatile WindowsContextSnapshot _current;
    private bool _attached;
    private int _snapshotsBuilt;

    private static readonly FocusMetrics DefaultFocusMetrics = new(
        SessionStartedAt: DateTimeOffset.UtcNow,
        FocusDuration: TimeSpan.Zero,
        AppSwitchesLast10Min: 0,
        DistractionCount: 0,
        ProductivityScore: 0,
        State: FocusState.Working,
        PrimaryApp: null,
        PrimaryWorkflow: WorkflowCategory.Unknown);

    public WindowsContextEngine(
        PerceptionService perception,
        IAppUsageTracker usageTracker,
        IWindowsContextSnapshotBuilder builder,
        IFocusSessionTracker focusTracker,
        IPresenceModeManager presenceManager,
        Func<ContextEngineSettings> settings,
        IDiagnostics? diagnostics = null)
    {
        _perception = perception;
        _usageTracker = usageTracker;
        _builder = builder;
        _focusTracker = focusTracker;
        _presenceManager = presenceManager;
        _settings = settings;
        _diagnostics = diagnostics;

        _current = MakeEmpty();
    }

    public WindowsContextSnapshot Current => _current;
    public event EventHandler<WindowsContextSnapshot>? ContextChanged;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_attached) return Task.CompletedTask;
        _perception.Changed += OnPerceptionChanged;
        _usageTracker.EntryAdded += OnEntryAdded;
        _focusTracker.MetricsChanged += OnFocusMetricsChanged;
        _presenceManager.ModeChanged += OnPresenceModeChanged;
        _attached = true;
        Rebuild();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!_attached) return Task.CompletedTask;
        _perception.Changed -= OnPerceptionChanged;
        _usageTracker.EntryAdded -= OnEntryAdded;
        _focusTracker.MetricsChanged -= OnFocusMetricsChanged;
        _presenceManager.ModeChanged -= OnPresenceModeChanged;
        _attached = false;
        return Task.CompletedTask;
    }

    private void OnPerceptionChanged(object? sender, SemanticSnapshot _) => Rebuild();
    private void OnEntryAdded(object? sender, AppUsageEntry _) => Rebuild();
    private void OnFocusMetricsChanged(object? sender, FocusMetrics _) => Rebuild();
    private void OnPresenceModeChanged(object? sender, PresenceMode _) => Rebuild();

    private void Rebuild()
    {
        if (!_settings().Enabled) return;

        var sw = System.Diagnostics.Stopwatch.StartNew();
        var semantic = _perception.LastBuilt;
        var recent = _usageTracker.GetRecent(_settings().TimelineSummaryDepth);
        var timeline = new PrivacySafeTimeline(recent, _settings().TimelineSummaryDepth);
        var focus = _focusTracker.Current;
        var presenceMode = _presenceManager.Current;

        var snap = _builder.Build(semantic, timeline, focus, presenceMode);
        sw.Stop();

        WindowsContextSnapshot? prev;
        bool changed;
        lock (_gate)
        {
            prev = _current;
            changed = snap.Hash != prev.Hash;
            if (changed)
            {
                _current = snap;
                _snapshotsBuilt++;
            }
        }

        if (changed)
        {
            _diagnostics?.RecordMetric("context.snapshotsBuilt", _snapshotsBuilt);
            _diagnostics?.RecordMetric("context.buildTimeMs", sw.Elapsed.TotalMilliseconds);
            ContextChanged?.Invoke(this, snap);
        }
    }

    private static WindowsContextSnapshot MakeEmpty() => new(
        CapturedAt: DateTimeOffset.UtcNow,
        Semantic: SemanticSnapshot.Empty,
        Timeline: PrivacySafeTimeline.Empty,
        RecentProcessNames: Array.Empty<string>(),
        Focus: DefaultFocusMetrics,
        PresenceMode: PresenceMode.Work,
        Hash: "0");
}
