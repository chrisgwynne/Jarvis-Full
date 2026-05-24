namespace Jarvis.Core.Automation;

public enum AutomationOutcome
{
    Succeeded,
    Failed,
    DeniedByPolicy,
    CancelledByUser,
    TimedOut,
    DryRunOnly
}

public sealed record AutomationResult(
    AutomationIntent Intent,
    AutomationPlan Plan,
    AutomationOutcome Outcome,
    string? Message,
    string? UndoHint,
    DateTimeOffset StartedAt,
    TimeSpan Duration)
{
    public bool Ok => Outcome == AutomationOutcome.Succeeded;
}
