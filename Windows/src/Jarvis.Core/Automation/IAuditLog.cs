namespace Jarvis.Core.Automation;

public sealed record AuditEntry(
    DateTimeOffset At,
    string IntentKind,
    string IntentSummary,
    SafetyTier Tier,
    string? TierReason,
    AutomationOutcome Outcome,
    string? Message,
    string? UndoHint,
    double DurationMs,
    string? Approver,
    string? PolicyVersion = null,
    string? DryRunHash = null);

public interface IAuditLog
{
    Task AppendAsync(AuditEntry entry, CancellationToken cancellationToken = default);
    IReadOnlyList<AuditEntry> Recent(int max = 200);
}
