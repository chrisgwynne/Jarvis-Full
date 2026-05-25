using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Context;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;
using Jarvis.DesktopAwareness;
using Xunit;

namespace Jarvis.Perception.Tests;

// ─── Stubs ───────────────────────────────────────────────────────────────────

/// <summary>Controllable stub for IDesktopAwarenessService.</summary>
file sealed class StubAwarenessService : IDesktopAwarenessService
{
    public DesktopSnapshot? Latest { get; private set; }
    public event EventHandler<DesktopSnapshot>? SnapshotChanged;

    public void Fire(DesktopSnapshot snap)
    {
        Latest = snap;
        SnapshotChanged?.Invoke(this, snap);
    }

    public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

/// <summary>Simple pass-through categorizer that infers workflow from process name.</summary>
file sealed class StubWorkflowCategorizer : IWorkflowCategorizer
{
    public WorkflowCategory Categorize(SemanticSnapshotInputs inputs)
    {
        var app = inputs.Desktop?.ForegroundProcessName ?? string.Empty;
        if (app.Equals("Code", StringComparison.OrdinalIgnoreCase)) return WorkflowCategory.Coding;
        if (app.Equals("chrome", StringComparison.OrdinalIgnoreCase)) return WorkflowCategory.Browsing;
        return WorkflowCategory.Unknown;
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

file static class Snap
{
    public static DesktopSnapshot For(string processName, string title = "Normal Title", DateTimeOffset? at = null) =>
        new(
            CapturedAt: at ?? DateTimeOffset.UtcNow,
            ForegroundProcessName: processName,
            ForegroundWindowTitle: title,
            ForegroundWindowHandle: 1,
            ActiveMonitorIndex: 0,
            ForegroundWindowBounds: Rect.Empty,
            UserIdleTime: TimeSpan.Zero,
            IsUserActive: true);
}

// ─── AppUsageTracker Tests ────────────────────────────────────────────────────

public class AppUsageTrackerTests
{
    private static AwarenessSettings DefaultSettings(int depth = 20) =>
        new AwarenessSettings { AppUsageHistoryDepth = depth };

    [Fact]
    public void AppUsageTracker_RecordsTransitionOnForegroundChange()
    {
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(), () => DefaultSettings());

        awareness.Fire(Snap.For("Code"));
        awareness.Fire(Snap.For("chrome"));

        var entries = tracker.GetRecent();
        entries.Should().HaveCount(1);
        entries[0].ProcessName.Should().Be("Code");
    }

    [Fact]
    public void AppUsageTracker_RecordsTwoTransitions()
    {
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(), () => DefaultSettings());

        awareness.Fire(Snap.For("Code"));
        awareness.Fire(Snap.For("chrome"));
        awareness.Fire(Snap.For("Code"));

        var entries = tracker.GetRecent();
        entries.Should().HaveCount(2);
        entries[0].ProcessName.Should().Be("Code");
        entries[1].ProcessName.Should().Be("chrome");
    }

    [Fact]
    public void AppUsageTracker_ComputesDwellTime()
    {
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(), () => DefaultSettings());

        var t0 = new DateTimeOffset(2024, 1, 1, 12, 0, 0, TimeSpan.Zero);
        var t1 = t0.AddMinutes(5);

        awareness.Fire(Snap.For("Code", at: t0));
        awareness.Fire(Snap.For("chrome", at: t1));

        var entries = tracker.GetRecent();
        entries.Should().HaveCount(1);
        entries[0].Dwell.Should().BeCloseTo(TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(1));
    }

    [Fact]
    public void AppUsageTracker_RedactsSensitiveTitle()
    {
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(), () => DefaultSettings());

        AppUsageEntry? captured = null;
        tracker.EntryAdded += (_, e) => captured = e;

        // Fire with a sensitive title while in process A.
        awareness.Fire(Snap.For("msedge", title: "Tab - InPrivate"));
        // Switch processes to finalise the entry.
        awareness.Fire(Snap.For("Code", title: "Normal Title - InPrivate"));

        // The entry was finalized when we switched from msedge to Code.
        captured.Should().NotBeNull();
        captured!.TitleRedacted.Should().BeTrue();
    }

    [Fact]
    public void AppUsageTracker_DoesNotRedactNormalTitle()
    {
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(), () => DefaultSettings());

        AppUsageEntry? captured = null;
        tracker.EntryAdded += (_, e) => captured = e;

        awareness.Fire(Snap.For("Code", title: "MyProject – Visual Studio Code"));
        awareness.Fire(Snap.For("chrome", title: "Normal window title"));

        captured.Should().NotBeNull();
        captured!.TitleRedacted.Should().BeFalse();
    }

    [Fact]
    public void AppUsageTracker_RingBufferCapsAtMaxEntries()
    {
        const int cap = 3;
        var awareness = new StubAwarenessService();
        var tracker = new AppUsageTracker(awareness, new StubWorkflowCategorizer(),
            () => DefaultSettings(depth: cap));

        // Generate 5 transitions so we exceed the cap.
        awareness.Fire(Snap.For("Code"));
        awareness.Fire(Snap.For("chrome"));
        awareness.Fire(Snap.For("Code"));
        awareness.Fire(Snap.For("chrome"));
        awareness.Fire(Snap.For("Code"));

        var entries = tracker.GetRecent(100);
        entries.Should().HaveCount(cap,
            "ring buffer should drop the oldest entries once the cap is reached");
    }
}

// ─── PrivacySafeTimeline Tests ────────────────────────────────────────────────

public class PrivacySafeTimelineTests
{
    private static AppUsageEntry MakeEntry(string process, WorkflowCategory wf, int dwellMinutes = 5) =>
        new(
            StartedAt: DateTimeOffset.UtcNow.AddMinutes(-dwellMinutes),
            Dwell: TimeSpan.FromMinutes(dwellMinutes),
            ProcessName: process,
            Workflow: wf,
            TitleRedacted: false);

    [Fact]
    public void PrivacySafeTimeline_BuildsFromEntries()
    {
        var entries = new[]
        {
            MakeEntry("Code", WorkflowCategory.Coding, 15),
            MakeEntry("chrome", WorkflowCategory.Browsing, 3)
        };
        var timeline = new PrivacySafeTimeline(entries);
        timeline.Entries.Should().HaveCount(2);
        timeline.Entries[0].ProcessName.Should().Be("Code");
        timeline.Entries[1].ProcessName.Should().Be("chrome");
    }

    [Fact]
    public void PrivacySafeTimeline_ToCompactSummary_FormatsCorrectly()
    {
        var entries = new[]
        {
            MakeEntry("Code", WorkflowCategory.Coding, 15),
            MakeEntry("chrome", WorkflowCategory.Browsing, 3),
            MakeEntry("Code", WorkflowCategory.Coding, 0)
        };
        var timeline = new PrivacySafeTimeline(entries);
        var summary = timeline.ToCompactSummary();

        // Last entry should be "now"; first two should have durations.
        summary.Should().Contain("Coding");
        summary.Should().Contain("Browsing");
        summary.Should().Contain("now");
        summary.Should().Contain("→");
    }

    [Fact]
    public void PrivacySafeTimeline_Empty_HasNoEntries()
    {
        PrivacySafeTimeline.Empty.Entries.Should().BeEmpty();
        PrivacySafeTimeline.Empty.ToCompactSummary().Should().BeEmpty();
    }
}

// ─── WindowsContextSnapshot Hash Tests ───────────────────────────────────────

public class WindowsContextSnapshotTests
{
    private static AppUsageEntry MakeEntry(string process, WorkflowCategory wf) =>
        new(DateTimeOffset.UtcNow, TimeSpan.FromMinutes(5), process, wf, false);

    [Fact]
    public void WindowsContextSnapshot_HashChangesOnAppTransition()
    {
        var builder = new Jarvis.Perception.Context.WindowsContextSnapshotBuilder();

        var snap1 = builder.Build(SemanticSnapshot.Empty, PrivacySafeTimeline.Empty);

        var entries = new[] { MakeEntry("Code", WorkflowCategory.Coding) };
        var timeline = new PrivacySafeTimeline(entries);
        var snap2 = builder.Build(SemanticSnapshot.Empty, timeline);

        snap1.Hash.Should().NotBe(snap2.Hash,
            "adding an app transition to the timeline should change the snapshot hash");
    }
}

// ─── DashboardViewModel Tests ─────────────────────────────────────────────────

public class DashboardViewModelTests
{
    private static AppUsageEntry MakeEntry(string process, WorkflowCategory wf) =>
        new(DateTimeOffset.UtcNow, TimeSpan.FromMinutes(5), process, wf, false);

    [Fact]
    public void DashboardViewModel_ApplyContextSnapshot_RaisesPropertyChanged()
    {
        var vm = new Jarvis.Perception.Dashboard.DashboardViewModel();
        var changedProperties = new List<string?>();
        vm.PropertyChanged += (_, e) => changedProperties.Add(e.PropertyName);

        var timeline = new PrivacySafeTimeline(new[] { MakeEntry("Code", WorkflowCategory.Coding) });
        var snap = new WindowsContextSnapshot(
            CapturedAt: DateTimeOffset.UtcNow,
            Semantic: SemanticSnapshot.Empty,
            Timeline: timeline,
            RecentProcessNames: new[] { "Code" },
            Hash: "abc123");

        vm.ApplyContextSnapshot(snap);

        changedProperties.Should().Contain(nameof(vm.CurrentWorkflow));
        changedProperties.Should().Contain(nameof(vm.RecentApps));
        changedProperties.Should().Contain(nameof(vm.TimelineSummary));
    }

    [Fact]
    public void DashboardViewModel_IncrementPublishedCount_IncrementsCounter()
    {
        var vm = new Jarvis.Perception.Dashboard.DashboardViewModel();
        vm.IncrementPublishedCount();
        vm.IncrementPublishedCount();
        vm.ContextPublishedCount.Should().Be(2);
    }
}
