namespace Jarvis.Core.Automation;

/// <summary>
/// What the planner says will happen if an intent is executed. Designed for two consumers:
/// the approval prompt (shows it to the user) and the audit log (records what was approved).
///
/// All fields are plain strings so the planner can be tested without any host environment.
/// </summary>
public sealed record AutomationPlan(
    string Headline,
    IReadOnlyList<string> Steps,
    string? Target,
    string? UndoHint,
    SafetyDecision Safety)
{
    public static AutomationPlan Of(string headline, SafetyDecision safety,
        IReadOnlyList<string>? steps = null, string? target = null, string? undoHint = null) =>
        new(headline, steps ?? Array.Empty<string>(), target, undoHint, safety);
}

public interface IDryRunPlanner
{
    AutomationPlan Plan(AutomationIntent intent);
}
