namespace Jarvis.Core.Automation;

/// <summary>
/// Decision the approval policy returns for every automation intent.
/// Higher tiers strictly require more user friction.
/// </summary>
public enum SafetyTier
{
    /// <summary>Read-only or trivially reversible. Executes immediately, audited only.</summary>
    Safe,

    /// <summary>Changes app state but low blast radius. A brief non-modal confirm-or-cancel
    /// toast is shown; auto-accepts after the cancel window elapses.</summary>
    Confirm,

    /// <summary>Significant side effect (creates files, launches apps, clicks specific UI).
    /// Modal approval dialog is mandatory; no default action.</summary>
    Approve,

    /// <summary>Matches a deny-list pattern (destructive, exfiltrating, privileged). Never executes.
    /// The policy must populate <see cref="SafetyDecision.BlockReason"/>.</summary>
    Block
}

/// <summary>
/// What the policy returns for one intent. Carries the tier plus a reason string so
/// the audit log records *why* a Block fired or which rule pinned a Confirm.
/// </summary>
public readonly record struct SafetyDecision(SafetyTier Tier, string Reason, string? BlockReason = null)
{
    public bool IsBlocked => Tier == SafetyTier.Block;
}

public interface IApprovalPolicy
{
    SafetyDecision Classify(AutomationIntent intent);

    /// <summary>Stable version string written into every audit entry so historic decisions
    /// can be reasoned about even after the rule set changes.</summary>
    string Version { get; }
}
