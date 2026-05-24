using System.Windows;
using System.Windows.Threading;
using Jarvis.Core.Automation;

namespace Jarvis.App.Automation;

public partial class ApprovalPromptWindow : Window
{
    private readonly TimeSpan? _autoApproveAfter;
    private DispatcherTimer? _countdown;
    private DateTimeOffset _deadline;
    private TaskCompletionSource<ApprovalDecision>? _tcs;

    public ApprovalPromptWindow(AutomationIntent intent, AutomationPlan plan, TimeSpan? autoApproveAfter = null)
    {
        InitializeComponent();
        _autoApproveAfter = autoApproveAfter;

        Headline.Text = plan.Headline;
        TierText.Text = $"{plan.Safety.Tier} · {plan.Safety.Reason}";
        StepsList.ItemsSource = plan.Steps;
        TargetText.Text = string.IsNullOrEmpty(plan.Target) ? "(none)" : plan.Target;
        UndoText.Text = string.IsNullOrEmpty(plan.UndoHint) ? "(no automatic undo)" : plan.UndoHint;

        if (_autoApproveAfter is { } d)
        {
            _deadline = DateTimeOffset.UtcNow + d;
            _countdown = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMilliseconds(100)
            };
            _countdown.Tick += (_, _) =>
            {
                var remaining = _deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero)
                {
                    _countdown!.Stop();
                    Complete(ApprovalOutcome.Approved, "auto-confirmed");
                    return;
                }
                CountdownText.Text = $"auto-approves in {remaining.TotalSeconds:F1}s — Esc to cancel";
            };
            _countdown.Start();
        }
        else
        {
            CountdownText.Text = "Press Approve to allow this action.";
        }

        Closed += (_, _) => _countdown?.Stop();
    }

    public Task<ApprovalDecision> WaitForDecisionAsync()
    {
        _tcs = new TaskCompletionSource<ApprovalDecision>(TaskCreationOptions.RunContinuationsAsynchronously);
        return _tcs.Task;
    }

    private void OnApprove(object sender, RoutedEventArgs e) => Complete(ApprovalOutcome.Approved, "user");
    private void OnDeny(object sender, RoutedEventArgs e) => Complete(ApprovalOutcome.Denied, "user");

    private void Complete(ApprovalOutcome outcome, string? note)
    {
        _countdown?.Stop();
        _tcs?.TrySetResult(new ApprovalDecision(outcome, note));
        Close();
    }
}
