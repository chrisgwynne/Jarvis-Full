using Jarvis.Core.Awareness;
using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Context;

/// <summary>
/// One entry in the privacy-safe timeline. Contains only the workflow category, process
/// name, and dwell duration — no window titles or URLs.
/// </summary>
public sealed record TimelineEntry(
    DateTimeOffset At,
    TimeSpan Dwell,
    string ProcessName,
    WorkflowCategory Workflow);

/// <summary>
/// An immutable, privacy-safe projection of recent app usage. Titles are never stored;
/// only process names and workflow categories. Suitable for inclusion in context payloads
/// sent to the Mac brain.
/// </summary>
public sealed class PrivacySafeTimeline
{
    private readonly TimelineEntry[] _entries;

    public PrivacySafeTimeline(IEnumerable<AppUsageEntry> source, int maxEntries = 10)
    {
        _entries = source
            .TakeLast(maxEntries)
            .Select(e => new TimelineEntry(
                At: e.StartedAt,
                Dwell: e.Dwell,
                ProcessName: e.ProcessName,
                Workflow: e.Workflow))
            .ToArray();
    }

    private PrivacySafeTimeline()
    {
        _entries = Array.Empty<TimelineEntry>();
    }

    public static PrivacySafeTimeline Empty { get; } = new();

    public IReadOnlyList<TimelineEntry> Entries => _entries;

    /// <summary>
    /// Returns a compact human-readable summary suitable for a context payload field,
    /// e.g. <c>"Coding(15m)→Browsing(3m)→Coding(now)"</c>.
    /// Returns an empty string when there are no entries.
    /// </summary>
    public string ToCompactSummary()
    {
        if (_entries.Length == 0) return string.Empty;

        var parts = new string[_entries.Length];
        for (var i = 0; i < _entries.Length; i++)
        {
            var e = _entries[i];
            var isLast = i == _entries.Length - 1;
            var duration = isLast ? "now" : FormatDwell(e.Dwell);
            parts[i] = $"{e.Workflow}({duration})";
        }
        return string.Join("→", parts);
    }

    private static string FormatDwell(TimeSpan dwell)
    {
        if (dwell.TotalSeconds < 60) return $"{(int)dwell.TotalSeconds}s";
        if (dwell.TotalHours < 1) return $"{(int)dwell.TotalMinutes}m";
        return $"{dwell.Hours}h{dwell.Minutes:D2}m";
    }
}
