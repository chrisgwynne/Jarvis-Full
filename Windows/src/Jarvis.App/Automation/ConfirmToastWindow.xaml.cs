using System.Windows;
using System.Windows.Threading;
using Jarvis.Core.Automation;
using Screen = System.Windows.Forms.Screen;

namespace Jarvis.App.Automation;

/// <summary>
/// Non-modal Confirm-tier prompt. Sits in the top-right of the primary monitor, never
/// steals focus, auto-confirms when the countdown bar drains. Cancel button denies the
/// action immediately. Approve-tier still uses <see cref="ApprovalPromptWindow"/>.
/// </summary>
public partial class ConfirmToastWindow : Window
{
    private readonly DispatcherTimer _timer;
    private readonly DateTimeOffset _deadline;
    private readonly TimeSpan _duration;
    private TaskCompletionSource<ApprovalDecision>? _tcs;

    public ConfirmToastWindow(AutomationIntent intent, AutomationPlan plan, TimeSpan duration)
    {
        InitializeComponent();
        ShowActivated = false;

        Headline.Text = plan.Headline;
        TierText.Text = $"{plan.Safety.Tier} · auto-confirms in {duration.TotalSeconds:F0}s";

        _duration = duration;
        _deadline = DateTimeOffset.UtcNow + duration;

        Loaded += (_, _) => PositionInTopRight();

        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(50) };
        _timer.Tick += (_, _) =>
        {
            var remaining = _deadline - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero)
            {
                _timer.Stop();
                Complete(ApprovalOutcome.Approved, "auto-confirmed");
                return;
            }
            Countdown.Value = remaining.TotalSeconds / _duration.TotalSeconds;
        };
        _timer.Start();
        Closed += (_, _) => _timer.Stop();
    }

    public Task<ApprovalDecision> WaitAsync()
    {
        _tcs = new TaskCompletionSource<ApprovalDecision>(TaskCreationOptions.RunContinuationsAsynchronously);
        return _tcs.Task;
    }

    private void PositionInTopRight()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
        Left = (screen.Right - ActualWidth) - 16;
        Top = screen.Top + 16;
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Complete(ApprovalOutcome.Denied, "user cancelled");

    private void Complete(ApprovalOutcome outcome, string? note)
    {
        _timer.Stop();
        _tcs?.TrySetResult(new ApprovalDecision(outcome, note));
        Close();
    }
}
