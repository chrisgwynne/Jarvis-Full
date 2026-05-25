using Jarvis.Core.Awareness;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;

namespace Jarvis.DesktopAwareness;

/// <summary>
/// Listens to <see cref="IDesktopAwarenessService.SnapshotChanged"/> and maintains a
/// bounded ring buffer of foreground-app sessions. Each time the foreground process
/// changes the previous entry is finalised with its dwell time and pushed to the buffer.
///
/// Privacy: window titles that match known sensitive patterns (InPrivate, incognito,
/// password managers, bank/PayPal) are dropped — only the process name and workflow
/// category are retained in those entries.
///
/// Thread-safety: all mutations are behind <c>lock (_gate)</c>.
/// </summary>
public sealed class AppUsageTracker : IAppUsageTracker
{
    // Sensitive-title keywords (case-insensitive prefix/substring matches).
    private static readonly string[] SensitivePatterns =
    {
        "incognito",
        "private browsing",
        " - inprivate",
        "password",
        "bank",
        "paypal",
        "1password",
        "bitwarden",
        "keepass"
    };

    private readonly IDesktopAwarenessService _awareness;
    private readonly IWorkflowCategorizer _categorizer;
    private readonly Func<AwarenessSettings> _settings;
    private readonly object _gate = new();

    // Ring buffer
    private AppUsageEntry[] _buffer;
    private int _count;
    private int _head; // index of the oldest entry

    // Pending (current) foreground session
    private string? _currentProcess;
    private DateTimeOffset _currentStartedAt;

    public AppUsageTracker(
        IDesktopAwarenessService awareness,
        IWorkflowCategorizer categorizer,
        Func<AwarenessSettings> settings)
    {
        _awareness = awareness;
        _categorizer = categorizer;
        _settings = settings;

        var capacity = Math.Max(1, settings().AppUsageHistoryDepth);
        _buffer = new AppUsageEntry[capacity];

        _awareness.SnapshotChanged += OnSnapshotChanged;
    }

    public event EventHandler<AppUsageEntry>? EntryAdded;

    public IReadOnlyList<AppUsageEntry> GetRecent(int maxEntries = 10)
    {
        lock (_gate)
        {
            var take = Math.Min(maxEntries, _count);
            if (take == 0) return Array.Empty<AppUsageEntry>();
            var capacity = _buffer.Length;
            var result = new AppUsageEntry[take];
            // Walk from oldest to newest within the ring.
            for (var i = 0; i < take; i++)
            {
                var idx = (_head + (_count - take) + i) % capacity;
                result[i] = _buffer[idx];
            }
            return result;
        }
    }

    private void OnSnapshotChanged(object? sender, DesktopSnapshot snap)
    {
        var newProcess = snap.ForegroundProcessName;

        AppUsageEntry? completed = null;
        lock (_gate)
        {
            // Resize if settings changed.
            var desired = Math.Max(1, _settings().AppUsageHistoryDepth);
            if (_buffer.Length != desired) ResizeBuffer(desired);

            if (string.Equals(_currentProcess, newProcess, StringComparison.Ordinal))
                return; // Same app — no transition yet.

            // Finalise the previous entry if we had one.
            if (_currentProcess is not null)
            {
                var dwell = snap.CapturedAt - _currentStartedAt;
                if (dwell < TimeSpan.Zero) dwell = TimeSpan.Zero;

                var workflow = CategorizeProcess(_currentProcess);
                var redacted = IsSensitiveTitle(snap.ForegroundWindowTitle);
                completed = new AppUsageEntry(
                    StartedAt: _currentStartedAt,
                    Dwell: dwell,
                    ProcessName: _currentProcess,
                    Workflow: workflow,
                    TitleRedacted: redacted);

                PushToBuffer(completed);
            }

            _currentProcess = newProcess;
            _currentStartedAt = snap.CapturedAt;
        }

        if (completed is not null)
            EntryAdded?.Invoke(this, completed);
    }

    private WorkflowCategory CategorizeProcess(string processName)
    {
        // Build minimal inputs to feed the categorizer.
        var fakeDesktop = new DesktopSnapshot(
            CapturedAt: DateTimeOffset.UtcNow,
            ForegroundProcessName: processName,
            ForegroundWindowTitle: string.Empty,
            ForegroundWindowHandle: 0,
            ActiveMonitorIndex: 0,
            ForegroundWindowBounds: Rect.Empty,
            UserIdleTime: TimeSpan.Zero,
            IsUserActive: true);

        var inputs = new Jarvis.Core.Snapshot.SemanticSnapshotInputs(
            Desktop: fakeDesktop,
            Selection: null,
            Clipboard: null,
            Browser: null,
            Ide: null,
            RecentOcr: null);

        return _categorizer.Categorize(inputs);
    }

    private static bool IsSensitiveTitle(string? title)
    {
        if (string.IsNullOrEmpty(title)) return false;
        foreach (var pattern in SensitivePatterns)
        {
            if (title.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    // Must be called under _gate.
    private void PushToBuffer(AppUsageEntry entry)
    {
        var capacity = _buffer.Length;
        if (_count < capacity)
        {
            // Buffer not yet full: write at tail.
            _buffer[(_head + _count) % capacity] = entry;
            _count++;
        }
        else
        {
            // Buffer full: overwrite oldest (head) and advance head.
            _buffer[_head] = entry;
            _head = (_head + 1) % capacity;
        }
    }

    // Rebuilds the ring buffer with a new capacity, preserving existing entries.
    // Must be called under _gate.
    private void ResizeBuffer(int newCapacity)
    {
        var old = GetRecentUnlocked(_count);
        _buffer = new AppUsageEntry[newCapacity];
        _head = 0;
        _count = 0;
        foreach (var e in old)
            PushToBuffer(e);
    }

    // Returns entries newest-last without acquiring the lock (caller must hold it).
    private AppUsageEntry[] GetRecentUnlocked(int take)
    {
        take = Math.Min(take, _count);
        if (take == 0) return Array.Empty<AppUsageEntry>();
        var capacity = _buffer.Length;
        var result = new AppUsageEntry[take];
        for (var i = 0; i < take; i++)
        {
            var idx = (_head + (_count - take) + i) % capacity;
            result[i] = _buffer[idx];
        }
        return result;
    }
}
