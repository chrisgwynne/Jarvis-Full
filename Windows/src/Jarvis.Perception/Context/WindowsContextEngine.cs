using Jarvis.Core.Awareness;
using Jarvis.Core.Context;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Context;

/// <summary>
/// Subscribes to perception and app-usage events and produces an up-to-date
/// <see cref="WindowsContextSnapshot"/> whenever something meaningful changes.
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
    private readonly Func<ContextEngineSettings> _settings;
    private readonly IDiagnostics? _diagnostics;

    private readonly object _gate = new();
    private volatile WindowsContextSnapshot _current;
    private bool _attached;
    private int _snapshotsBuilt;

    public WindowsContextEngine(
        PerceptionService perception,
        IAppUsageTracker usageTracker,
        IWindowsContextSnapshotBuilder builder,
        Func<ContextEngineSettings> settings,
        IDiagnostics? diagnostics = null)
    {
        _perception = perception;
        _usageTracker = usageTracker;
        _builder = builder;
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
        _attached = true;
        Rebuild();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!_attached) return Task.CompletedTask;
        _perception.Changed -= OnPerceptionChanged;
        _usageTracker.EntryAdded -= OnEntryAdded;
        _attached = false;
        return Task.CompletedTask;
    }

    private void OnPerceptionChanged(object? sender, SemanticSnapshot _) => Rebuild();
    private void OnEntryAdded(object? sender, AppUsageEntry _) => Rebuild();

    private void Rebuild()
    {
        if (!_settings().Enabled) return;

        var sw = System.Diagnostics.Stopwatch.StartNew();
        var semantic = _perception.LastBuilt;
        var recent = _usageTracker.GetRecent(_settings().TimelineSummaryDepth);
        var timeline = new PrivacySafeTimeline(recent, _settings().TimelineSummaryDepth);

        var snap = _builder.Build(semantic, timeline);
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
        Hash: "0");
}
