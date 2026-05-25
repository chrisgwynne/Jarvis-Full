using System.ComponentModel;
using System.Runtime.CompilerServices;
using Jarvis.Core.Context;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Dashboard;

/// <summary>
/// View model for a dashboard panel that reflects the current Windows context engine
/// state. Implements <see cref="INotifyPropertyChanged"/> for WPF data binding.
///
/// Update paths:
///   - <see cref="ApplyContextSnapshot"/> — called from <see cref="IWindowsContextEngine.ContextChanged"/>
///   - <see cref="BridgeStatus"/> — set by bridge status change handlers
///   - <see cref="IncrementPublishedCount"/> — called each time a context frame is pushed to the Mac
/// </summary>
public sealed class DashboardViewModel : INotifyPropertyChanged
{
    private string _currentWorkflow = WorkflowCategory.Unknown.ToString();
    private string _bridgeStatus = "Disconnected";
    private string[] _recentApps = Array.Empty<string>();
    private string _timelineSummary = "";
    private int _contextPublishedCount;
    private FocusState _focusState = FocusState.Working;
    private string _focusDurationDisplay = "0 min";
    private int _appSwitchesLast10Min;
    private double _productivityScore;
    private PresenceMode _presenceMode = PresenceMode.Work;
    private string _smartSuggestion = "";

    public string CurrentWorkflow
    {
        get => _currentWorkflow;
        private set => Set(ref _currentWorkflow, value);
    }

    public string BridgeStatus
    {
        get => _bridgeStatus;
        set => Set(ref _bridgeStatus, value);
    }

    public string[] RecentApps
    {
        get => _recentApps;
        private set => Set(ref _recentApps, value);
    }

    public string TimelineSummary
    {
        get => _timelineSummary;
        private set => Set(ref _timelineSummary, value);
    }

    public int ContextPublishedCount
    {
        get => _contextPublishedCount;
        private set => Set(ref _contextPublishedCount, value);
    }

    public FocusState FocusState
    {
        get => _focusState;
        private set => Set(ref _focusState, value);
    }

    public string FocusDurationDisplay
    {
        get => _focusDurationDisplay;
        private set => Set(ref _focusDurationDisplay, value);
    }

    public int AppSwitchesLast10Min
    {
        get => _appSwitchesLast10Min;
        private set => Set(ref _appSwitchesLast10Min, value);
    }

    public double ProductivityScore
    {
        get => _productivityScore;
        private set => Set(ref _productivityScore, value);
    }

    public PresenceMode PresenceMode
    {
        get => _presenceMode;
        private set => Set(ref _presenceMode, value);
    }

    public string SmartSuggestion
    {
        get => _smartSuggestion;
        private set => Set(ref _smartSuggestion, value);
    }

    /// <summary>Applies a new context snapshot, updating workflow, recent apps, timeline, focus, and presence.</summary>
    public void ApplyContextSnapshot(WindowsContextSnapshot snap)
    {
        CurrentWorkflow = snap.Semantic.Workflow.ToString();
        RecentApps = snap.RecentProcessNames;
        TimelineSummary = snap.Timeline.ToCompactSummary();

        var focus = snap.Focus;
        FocusState = focus.State;
        FocusDurationDisplay = FormatFocusDuration(focus.FocusDuration);
        AppSwitchesLast10Min = focus.AppSwitchesLast10Min;
        ProductivityScore = focus.ProductivityScore;
        PresenceMode = snap.PresenceMode;
        SmartSuggestion = ComputeSmartSuggestion(focus, snap.PresenceMode);
    }

    /// <summary>Increments the count of context frames successfully published to the Mac bridge.</summary>
    public void IncrementPublishedCount() => ContextPublishedCount++;

    public event PropertyChangedEventHandler? PropertyChanged;

    private static string FormatFocusDuration(TimeSpan duration)
    {
        if (duration.TotalMinutes >= 60)
        {
            var h = (int)duration.TotalHours;
            var m = duration.Minutes;
            return $"{h}h {m}m";
        }
        return $"{(int)duration.TotalMinutes} min";
    }

    private static string ComputeSmartSuggestion(FocusMetrics focus, PresenceMode presenceMode)
    {
        var switches = focus.AppSwitchesLast10Min;
        var duration = focus.FocusDuration;

        if (presenceMode == PresenceMode.Gaming)
            return "Gaming mode — proactive suggestions paused.";
        if (presenceMode == PresenceMode.Presentation)
            return "Presentation mode detected — staying quiet.";
        if (switches >= 15)
            return $"You've switched apps {switches} times in the last 10 minutes.";
        if (duration.TotalMinutes >= 120 && switches <= 3)
        {
            var h = (int)duration.TotalHours;
            var m = duration.Minutes;
            return $"You've been coding for {h}h {m}m uninterrupted.";
        }
        if (duration.TotalMinutes >= 25 && switches <= 5)
            return $"Good focus session — {(int)duration.TotalMinutes} min and counting.";
        return "";
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
