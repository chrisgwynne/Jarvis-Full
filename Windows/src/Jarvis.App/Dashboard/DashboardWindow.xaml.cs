using System.Windows;
using System.Windows.Media;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Perception.Dashboard;

namespace Jarvis.App.Dashboard;

public partial class DashboardWindow : Window
{
    private const double ProductivityBarMaxWidth = 380.0;

    /// <summary>Raised when the user clicks a quick-action button.</summary>
    public event EventHandler<string>? QuickActionRequested;

    public DashboardWindow(DashboardViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        vm.PropertyChanged += (_, e) =>
        {
            Dispatcher.BeginInvoke(Refresh);
            if (e.PropertyName == nameof(DashboardViewModel.RecentToolRuns))
                Dispatcher.BeginInvoke(RefreshToolRuns);
        };
        Loaded += (_, _) => Refresh();
    }

    private void Refresh()
    {
        if (DataContext is not DashboardViewModel vm) return;

        // Card 1: Status
        PresenceModeText.Text = FormatPresenceMode(vm.PresenceMode);
        StatusIndicator.Fill = GetStatusBrush(vm.PresenceMode, vm.BridgeStatus);
        BridgeStatusText.Text = $"Mac: {vm.BridgeStatus}";
        MacConnectionText.Text = vm.BridgeStatus.StartsWith("Connected", StringComparison.OrdinalIgnoreCase)
            ? "Mac Connected" : "Mac Disconnected";

        // Card 2: Focus
        FocusDurationText.Text = vm.FocusDurationDisplay;
        FocusStateText.Text = vm.FocusState.ToString();
        var barWidth = Math.Max(0, Math.Min(ProductivityBarMaxWidth, vm.ProductivityScore * ProductivityBarMaxWidth));
        ProductivityBar.Width = barWidth;
        ProductivityScoreText.Text = $"Productivity: {vm.ProductivityScore * 100:F0}%";

        // Card 3: Activity
        WorkflowText.Text = vm.CurrentWorkflow;
        AppSwitchesText.Text = $"{vm.AppSwitchesLast10Min} app switches in last 10 min";

        if (!string.IsNullOrEmpty(vm.SmartSuggestion))
        {
            SmartSuggestionText.Text = vm.SmartSuggestion;
            SmartSuggestionText.Visibility = Visibility.Visible;
        }
        else
        {
            SmartSuggestionText.Visibility = Visibility.Collapsed;
        }

        // Card 4: Today
        var timeline = vm.TimelineSummary;
        TimelineSummaryText.Text = string.IsNullOrEmpty(timeline)
            ? "Session tracking initializing..."
            : timeline;
    }

    private void RefreshToolRuns()
    {
        if (DataContext is not DashboardViewModel vm) return;
        var runs = vm.RecentToolRuns;

        if (runs.Count == 0)
        {
            RecentToolRunsCard.Visibility = Visibility.Collapsed;
            return;
        }

        RecentToolRunsCard.Visibility = Visibility.Visible;
        RecentToolRunsList.ItemsSource = runs
            .OrderByDescending(r => r.At)
            .Take(5)
            .Select(r => new
            {
                StatusGlyph = r.Success ? "✓" : "✗",
                Summary = $"{r.ToolName}: {r.Summary}",
                TimeDisplay = r.At.LocalDateTime.ToString("HH:mm")
            })
            .ToList();
    }

    // ─── Quick Action handlers ─────────────────────────────────────────────────

    private void OnFocusModeBtn(object sender, RoutedEventArgs e) =>
        QuickActionRequested?.Invoke(this, "toggle_focus");

    private void OnScreenshotBtn(object sender, RoutedEventArgs e) =>
        QuickActionRequested?.Invoke(this, "screenshot");

    private void OnRunningAppsBtn(object sender, RoutedEventArgs e) =>
        QuickActionRequested?.Invoke(this, "running_apps");

    // ─── Helpers ───────────────────────────────────────────────────────────────

    private static string FormatPresenceMode(PresenceMode mode) => mode switch
    {
        PresenceMode.Work         => "Work",
        PresenceMode.Focus        => "Focus",
        PresenceMode.Casual       => "Casual",
        PresenceMode.Gaming       => "Gaming",
        PresenceMode.Presentation => "Presentation",
        PresenceMode.Silent       => "Silent",
        PresenceMode.Developer    => "Developer",
        _                         => mode.ToString()
    };

    private static System.Windows.Media.Brush GetStatusBrush(PresenceMode mode, string bridgeStatus)
    {
        if (mode == PresenceMode.Silent)
            return System.Windows.Media.Brushes.Gray;
        if (bridgeStatus.StartsWith("Connected", StringComparison.OrdinalIgnoreCase))
            return new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x22, 0xC5, 0x5E));
        return new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0xF5, 0x9E, 0x0B));
    }
}
