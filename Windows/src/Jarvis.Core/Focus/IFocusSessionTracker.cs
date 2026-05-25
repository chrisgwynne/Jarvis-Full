using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Focus;

public enum FocusState { Idle, Distracted, Working, Focused, DeepWork }

public sealed record FocusMetrics(
    DateTimeOffset SessionStartedAt,
    TimeSpan FocusDuration,
    int AppSwitchesLast10Min,
    int DistractionCount,
    double ProductivityScore,
    FocusState State,
    string? PrimaryApp,
    WorkflowCategory PrimaryWorkflow);

public interface IFocusSessionTracker
{
    FocusMetrics Current { get; }
    event EventHandler<FocusMetrics>? MetricsChanged;
    Task StartAsync(CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
}
