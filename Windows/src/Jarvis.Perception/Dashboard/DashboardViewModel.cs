using System.ComponentModel;
using System.Runtime.CompilerServices;
using Jarvis.Core.Context;
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

    /// <summary>Applies a new context snapshot, updating workflow, recent apps, and timeline.</summary>
    public void ApplyContextSnapshot(WindowsContextSnapshot snap)
    {
        CurrentWorkflow = snap.Semantic.Workflow.ToString();
        RecentApps = snap.RecentProcessNames;
        TimelineSummary = snap.Timeline.ToCompactSummary();
    }

    /// <summary>Increments the count of context frames successfully published to the Mac bridge.</summary>
    public void IncrementPublishedCount() => ContextPublishedCount++;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
