using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Awareness;

public interface IAppUsageTracker
{
    IReadOnlyList<AppUsageEntry> GetRecent(int maxEntries = 10);
    event EventHandler<AppUsageEntry>? EntryAdded;
}

/// <summary>
/// Immutable record of one foreground-app session. TitleRedacted is true when the window
/// title matched a privacy-sensitive pattern (private browsing, password managers, etc.)
/// and was dropped rather than recorded.
/// </summary>
public sealed record AppUsageEntry(
    DateTimeOffset StartedAt,
    TimeSpan Dwell,
    string ProcessName,
    WorkflowCategory Workflow,
    bool TitleRedacted);
