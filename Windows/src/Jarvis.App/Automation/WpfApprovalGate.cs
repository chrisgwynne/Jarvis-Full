using System.Windows;
using Jarvis.Core.Automation;

namespace Jarvis.App.Automation;

/// <summary>
/// Routes approval requests to the correct UI surface based on safety tier:
///   - Confirm  → <see cref="ConfirmToastWindow"/> (non-modal, top-right, auto-confirm 3s)
///   - Approve  → <see cref="ApprovalPromptWindow"/> (modal, no default action)
/// </summary>
public sealed class WpfApprovalGate : IApprovalGate
{
    private readonly TimeSpan _confirmDuration = TimeSpan.FromSeconds(3);

    public async Task<ApprovalDecision> RequestAsync(AutomationIntent intent, AutomationPlan plan, CancellationToken cancellationToken = default)
    {
        var app = System.Windows.Application.Current;
        if (app is null) return new ApprovalDecision(ApprovalOutcome.Denied, "no application");

        return await app.Dispatcher.InvokeAsync(async () =>
        {
            // Remote-origin intents (Mac bridge) never auto-confirm: always use the
            // modal dialog so the user must explicitly approve (#50).
            if (plan.Safety.Tier == SafetyTier.Confirm && !intent.IsRemoteOrigin)
            {
                var toast = new ConfirmToastWindow(intent, plan, _confirmDuration);
                toast.Show();
                using var _ = cancellationToken.Register(() => toast.Dispatcher.BeginInvoke(toast.Close));
                return await toast.WaitAsync().ConfigureAwait(true);
            }
            var window = new ApprovalPromptWindow(intent, plan, autoApproveAfter: null);
            window.Show();
            window.Activate();
            using var __ = cancellationToken.Register(() => window.Dispatcher.BeginInvoke(window.Close));
            return await window.WaitForDecisionAsync().ConfigureAwait(true);
        }).Task.Unwrap().ConfigureAwait(false);
    }
}
