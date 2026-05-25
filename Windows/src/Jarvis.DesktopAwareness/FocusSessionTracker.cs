using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Focus;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;

namespace Jarvis.DesktopAwareness;

/// <summary>
/// Derives focus session metrics from the app usage stream. Subscribes to
/// <see cref="IAppUsageTracker.EntryAdded"/> and maintains a bounded sliding window
/// of the last 10 minutes. All state changes are protected by <c>lock (_gate)</c>.
/// </summary>
public sealed class FocusSessionTracker : IFocusSessionTracker
{
    private const int MaxWindowEntries = 50;
    private const int DistractionLoopThreshold = 10;
    private const double DeepWorkMinutes = 90;
    private const double FocusedMinutes = 20;
    private const int DeepWorkMaxSwitches = 2;
    private const int FocusedMaxSwitches = 5;
    private const int MeaningfulSwitchDelta = 2;

    private static readonly HashSet<WorkflowCategory> DistractionWorkflows = new()
    {
        WorkflowCategory.Media,
        WorkflowCategory.Gaming,
        WorkflowCategory.Shopping,
        WorkflowCategory.Unknown
    };

    private readonly IAppUsageTracker _usageTracker;
    private readonly Func<AwarenessSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();

    // Bounded sliding window (last 10 min, max MaxWindowEntries)
    private readonly Queue<AppUsageEntry> _window = new(MaxWindowEntries + 1);

    private DateTimeOffset _sessionStart = DateTimeOffset.UtcNow;
    private int _distractionCount;
    private FocusMetrics _current;
    private FocusState _lastFiredState = FocusState.Working;
    private int _lastFiredSwitches = 0;
    private bool _started;

    public FocusSessionTracker(IAppUsageTracker usageTracker, Func<AwarenessSettings> settings, IDiagnostics? diagnostics = null)
    {
        _usageTracker = usageTracker;
        _settings = settings;
        _diagnostics = diagnostics;
        _current = MakeInitialMetrics();
    }

    public FocusMetrics Current => _current;
    public event EventHandler<FocusMetrics>? MetricsChanged;

    public Task StartAsync(CancellationToken ct = default)
    {
        if (_started) return Task.CompletedTask;
        _usageTracker.EntryAdded += OnEntryAdded;
        _started = true;
        _diagnostics?.Record(DiagnosticLevel.Info, "focus", "tracker started");
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        if (!_started) return Task.CompletedTask;
        _usageTracker.EntryAdded -= OnEntryAdded;
        _started = false;
        _diagnostics?.Record(DiagnosticLevel.Info, "focus", "tracker stopped");
        return Task.CompletedTask;
    }

    private void OnEntryAdded(object? sender, AppUsageEntry entry)
    {
        FocusMetrics? newMetrics = null;
        bool shouldFire = false;

        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            var cutoff = now.AddMinutes(-10);

            // Add new entry and trim beyond 10-min window AND max 50 entries
            _window.Enqueue(entry);

            // Remove entries older than 10 min from front
            while (_window.Count > 0 && _window.Peek().StartedAt < cutoff)
                _window.Dequeue();

            // Enforce max capacity
            while (_window.Count > MaxWindowEntries)
                _window.Dequeue();

            int switches = _window.Count;

            // Reset session if distraction loop detected
            if (switches >= DistractionLoopThreshold)
            {
                _sessionStart = now;
                _distractionCount = 0;
            }

            // Count distractions in session (since _sessionStart)
            if (DistractionWorkflows.Contains(entry.Workflow))
                _distractionCount++;

            var focusDuration = now - _sessionStart;
            var state = InferState(entry, switches, focusDuration);
            var primaryApp = GetMode(_window.Skip(Math.Max(0, _window.Count - 20)).Select(e => e.ProcessName));
            var primaryWorkflow = GetModeWorkflow(_window.Skip(Math.Max(0, _window.Count - 20)).Select(e => e.Workflow));
            var productivityScore = ComputeProductivityScore(focusDuration, _distractionCount);

            newMetrics = new FocusMetrics(
                SessionStartedAt: _sessionStart,
                FocusDuration: focusDuration,
                AppSwitchesLast10Min: switches,
                DistractionCount: _distractionCount,
                ProductivityScore: productivityScore,
                State: state,
                PrimaryApp: primaryApp,
                PrimaryWorkflow: primaryWorkflow);

            _current = newMetrics;

            // Fire only on meaningful state change or switch delta >= 2
            shouldFire = state != _lastFiredState
                || Math.Abs(switches - _lastFiredSwitches) >= MeaningfulSwitchDelta;

            if (shouldFire)
            {
                _lastFiredState = state;
                _lastFiredSwitches = switches;
            }
        }

        if (shouldFire && newMetrics is not null)
            MetricsChanged?.Invoke(this, newMetrics);
    }

    private static FocusState InferState(AppUsageEntry lastEntry, int switches, TimeSpan focusDuration)
    {
        if (lastEntry.Workflow == WorkflowCategory.Idle)
            return FocusState.Idle;

        if (switches >= DistractionLoopThreshold && focusDuration.TotalMinutes < 5)
            return FocusState.Distracted;

        if (focusDuration.TotalMinutes >= DeepWorkMinutes && switches <= DeepWorkMaxSwitches)
            return FocusState.DeepWork;

        if (focusDuration.TotalMinutes >= FocusedMinutes && switches <= FocusedMaxSwitches)
            return FocusState.Focused;

        return FocusState.Working;
    }

    private static double ComputeProductivityScore(TimeSpan focusDuration, int distractionCount)
    {
        var raw = focusDuration.TotalMinutes / 60.0 * (1 - distractionCount * 0.05);
        return Math.Clamp(raw, 0.0, 1.0);
    }

    private static string? GetMode(IEnumerable<string> items)
    {
        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in items)
        {
            if (string.IsNullOrEmpty(item)) continue;
            counts[item] = counts.TryGetValue(item, out var c) ? c + 1 : 1;
        }
        if (counts.Count == 0) return null;
        return counts.MaxBy(kv => kv.Value).Key;
    }

    private static WorkflowCategory GetModeWorkflow(IEnumerable<WorkflowCategory> items)
    {
        var counts = new Dictionary<WorkflowCategory, int>();
        foreach (var item in items)
            counts[item] = counts.TryGetValue(item, out var c) ? c + 1 : 1;
        if (counts.Count == 0) return WorkflowCategory.Unknown;
        return counts.MaxBy(kv => kv.Value).Key;
    }

    private static FocusMetrics MakeInitialMetrics() => new(
        SessionStartedAt: DateTimeOffset.UtcNow,
        FocusDuration: TimeSpan.Zero,
        AppSwitchesLast10Min: 0,
        DistractionCount: 0,
        ProductivityScore: 0,
        State: FocusState.Working,
        PrimaryApp: null,
        PrimaryWorkflow: WorkflowCategory.Unknown);
}
