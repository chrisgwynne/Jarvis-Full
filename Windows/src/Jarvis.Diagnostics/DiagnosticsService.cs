using System.Collections.Concurrent;
using Jarvis.Core.Diagnostics;

namespace Jarvis.Diagnostics;

/// <summary>
/// In-process diagnostics sink. Bounded ring buffer + concurrent metric map.
/// No I/O on the hot path — file flush is the caller's job (Phase 2).
/// </summary>
public sealed class DiagnosticsService : IDiagnostics
{
    private readonly int _capacity;
    private readonly object _gate = new();
    private readonly Queue<DiagnosticEntry> _entries;
    private readonly ConcurrentDictionary<string, double> _metrics = new();

    public DiagnosticsService(int capacity = 1024)
    {
        if (capacity <= 0) throw new ArgumentOutOfRangeException(nameof(capacity));
        _capacity = capacity;
        _entries = new Queue<DiagnosticEntry>(capacity);
    }

    public IReadOnlyDictionary<string, double> Metrics => _metrics;

    public void Record(DiagnosticLevel level, string category, string message, IReadOnlyDictionary<string, object?>? properties = null)
    {
        var entry = new DiagnosticEntry(DateTimeOffset.UtcNow, level, category, message, properties);
        lock (_gate)
        {
            if (_entries.Count == _capacity) _entries.Dequeue();
            _entries.Enqueue(entry);
        }
    }

    public IReadOnlyList<DiagnosticEntry> Recent(int max = 200)
    {
        lock (_gate)
        {
            if (max >= _entries.Count) return _entries.ToArray();
            return _entries.Skip(_entries.Count - max).ToArray();
        }
    }

    public void RecordMetric(string name, double value) => _metrics[name] = value;
}
