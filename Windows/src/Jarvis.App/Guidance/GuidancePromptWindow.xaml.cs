using System.Windows;
using System.Windows.Input;
using Jarvis.Core.Automation;
using Jarvis.Core.Guidance;
using Screen = System.Windows.Forms.Screen;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace Jarvis.App.Guidance;

public partial class GuidancePromptWindow : Window
{
    private readonly IGuidanceService _guidance;
    private readonly IAutomationExecutor _executor;
    private GuidanceResult? _last;

    public GuidancePromptWindow(IGuidanceService guidance, IAutomationExecutor executor)
    {
        _guidance = guidance;
        _executor = executor;
        InitializeComponent();
        Loaded += (_, _) => QueryBox.Focus();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    private async void OnAsk(object sender, RoutedEventArgs e) => await AskAsync();

    private async void OnQueryKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await AskAsync();
    }

    private async Task AskAsync()
    {
        var query = QueryBox.Text.Trim();
        if (string.IsNullOrEmpty(query)) return;
        ResultText.Text = "Looking…";
        CandidatesList.ItemsSource = null;
        ClickItBtn.IsEnabled = false;

        try
        {
            _last = await _guidance.AskAsync(query);
            ResultText.Text = _last.Explanation;
            CandidatesList.ItemsSource = _last.Candidates
                .Take(6)
                .Select(c => $"{c.Score:F2}  [{c.Target.Source}]  {c.Target.Role,-10}  {Trunc(c.Target.Label, 60)}")
                .ToList();
            ClickItBtn.IsEnabled = _last.SuggestedClick is not null;

            // Non-intrusive: when a target was found AND keep-open is off, park the
            // prompt in the bottom-right corner so it doesn't cover the highlight.
            if (_last.Found && KeepOpenCheck.IsChecked != true)
                ParkInBottomRight();
        }
        catch (OperationCanceledException)
        {
            ResultText.Text = "(superseded by a newer query)";
        }
        catch (Exception ex)
        {
            ResultText.Text = $"Failed: {ex.Message}";
        }
    }

    private void ParkInBottomRight()
    {
        var screen = Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1920, 1080);
        Left = (screen.Right - ActualWidth) - 16;
        Top = (screen.Bottom - ActualHeight) - 16;
        Opacity = 0.85;
    }

    private async void OnClickIt(object sender, RoutedEventArgs e)
    {
        if (_last?.SuggestedClick is not { } intent) return;
        Close();
        await _executor.ExecuteAsync(intent);
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private static string Trunc(string s, int n) => s.Length <= n ? s : s[..n] + "…";
}
