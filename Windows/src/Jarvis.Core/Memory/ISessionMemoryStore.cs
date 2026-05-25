using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Memory;

public sealed record WorkSession(
    string Id,
    DateTimeOffset StartedAt,
    DateTimeOffset EndedAt,
    WorkflowCategory PrimaryWorkflow,
    string? PrimaryApp,
    TimeSpan TotalFocusDuration,
    int TotalAppSwitches,
    double PeakProductivityScore,
    string TimelineSummary);

public interface ISessionMemoryStore
{
    Task<IReadOnlyList<WorkSession>> GetTodayAsync();
    Task<IReadOnlyList<WorkSession>> GetRecentAsync(int days = 7);
    Task SaveSessionAsync(WorkSession session);
    Task ClearAsync();
    Task<long> GetStoreSizeAsync();
}
