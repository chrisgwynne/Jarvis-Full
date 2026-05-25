using System.Windows;
using System.Windows.Media;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Perception.Dashboard;

namespace Jarvis.App.Dashboard;

public partial class DashboardWindow : Window
{
    private const double ProductivityBarMaxWidth = 380.0;

    public DashboardWindow(DashboardViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        vm.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
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

    private static Brush GetStatusBrush(PresenceMode mode, string bridgeStatus)
    {
        if (mode == PresenceMode.Silent)
            return Brushes.Gray;
        if (bridgeStatus.StartsWith("Connected", StringComparison.OrdinalIgnoreCase))
            return new SolidColorBrush(Color.FromRgb(0x22, 0xC5, 0x5E));
        return new SolidColorBrush(Color.FromRgb(0xF5, 0x9E, 0x0B));
    }
}
