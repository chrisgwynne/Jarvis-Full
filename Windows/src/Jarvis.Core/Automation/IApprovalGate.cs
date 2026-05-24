namespace Jarvis.Core.Automation;

public enum ApprovalOutcome { Approved, Denied, TimedOut }

public readonly record struct ApprovalDecision(ApprovalOutcome Outcome, string? Note = null);

/// <summary>
/// User-facing approval surface. Implementations:
///   - WPF modal dialog for <see cref="SafetyTier.Approve"/>
///   - Non-modal countdown toast for <see cref="SafetyTier.Confirm"/>
///   - Null gate that auto-approves (tests only)
/// </summary>
public interface IApprovalGate
{
    Task<ApprovalDecision> RequestAsync(AutomationIntent intent, AutomationPlan plan, CancellationToken cancellationToken = default);
}

public sealed class AutoApproveGate : IApprovalGate
{
    public Task<ApprovalDecision> RequestAsync(AutomationIntent intent, AutomationPlan plan, CancellationToken cancellationToken = default)
        => Task.FromResult(new ApprovalDecision(ApprovalOutcome.Approved, "auto (test)"));
}
