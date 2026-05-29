using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Focus;
using Jarvis.Core.Memory;
using Jarvis.Core.Settings;
using Jarvis.Core.Snapshot;
using Jarvis.Core.Tools;
using Jarvis.Perception.Dashboard;
using Jarvis.Perception.Memory;
using Jarvis.Perception.Tools;
using Xunit;

namespace Jarvis.Perception.Tests;

// ─── Registry tests ───────────────────────────────────────────────────────────

public class ToolRegistryTests
{
    private static IWindowsToolRegistry MakeRegistry(bool enabled = true)
    {
        var tools = new IWindowsTool[] { new OpenAppTool(), new FocusAppTool() };
        return new WindowsToolRegistry(tools, () => new ToolsSettings { Enabled = enabled });
    }

    [Fact]
    public void ToolRegistry_FindByName_ReturnsCorrectTool()
    {
        var reg = MakeRegistry();
        var tool = reg.Find("open_app");
        tool.Should().NotBeNull();
        tool!.Name.Should().Be("open_app");
    }

    [Fact]
    public void ToolRegistry_FindByAlias_ReturnsCorrectTool()
    {
        var reg = MakeRegistry();
        var tool = reg.Find("launch");    // alias of open_app
        tool.Should().NotBeNull();
        tool!.Name.Should().Be("open_app");
    }

    [Fact]
    public void ToolRegistry_Disabled_ReturnsNull()
    {
        var reg = MakeRegistry(enabled: false);
        var tool = reg.Find("open_app");
        tool.Should().BeNull();
    }
}

// ─── OpenAppTool tests ────────────────────────────────────────────────────────

public class OpenAppToolTests
{
    private static WindowsToolRequest MakeRequest(string app, bool dryRun = false) =>
        new("test", "open_app", new Dictionary<string, string> { ["app"] = app }, dryRun, "test",
            DateTimeOffset.UtcNow);

    [Fact]
    public async Task OpenAppTool_UnknownAlias_ReturnsFailure()
    {
        var tool = new OpenAppTool();
        var result = await tool.ExecuteAsync(MakeRequest("totally-unknown-app-xyz"));
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("Unknown app");
    }

    [Fact]
    public async Task OpenAppTool_DryRun_DoesNotLaunch()
    {
        var tool = new OpenAppTool();
        // "notepad" is a known alias — dry run should not actually launch
        var result = await tool.ExecuteAsync(MakeRequest("notepad", dryRun: true));
        result.Success.Should().BeTrue();
        result.Summary.Should().Contain("Would open");
    }
}

// ─── FocusAppTool tests ───────────────────────────────────────────────────────

public class FocusAppToolTests
{
    [Fact]
    public async Task FocusAppTool_NotRunning_ReturnsFailure()
    {
        var tool = new FocusAppTool();
        // Use a process name that is definitely not running
        var req = new WindowsToolRequest("test", "focus_app",
            new Dictionary<string, string> { ["app"] = "definitely_not_running_xyzzy_999" },
            false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("does not appear to be running");
    }
}

// ─── CloseAppTool tests ───────────────────────────────────────────────────────

public class CloseAppToolTests
{
    [Fact]
    public async Task CloseAppTool_BlockedWhenSettingDisabled()
    {
        var tool = new CloseAppTool(() => new ToolsSettings { AllowAppClose = false });
        var req = new WindowsToolRequest("test", "close_app",
            new Dictionary<string, string> { ["app"] = "notepad" },
            false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("disabled");
    }
}

// ─── ScreenshotWindowTool tests ───────────────────────────────────────────────

public class ScreenshotWindowToolTests
{
    [Fact]
    public async Task ScreenshotWindowTool_BlockedWhenSettingDisabled()
    {
        var tool = new ScreenshotWindowTool(() => new ToolsSettings { AllowScreenshots = false });
        var req = new WindowsToolRequest("test", "screenshot_window",
            new Dictionary<string, string>(), false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("disabled");
    }
}

// ─── ClipboardSummaryTool tests ───────────────────────────────────────────────

public class ClipboardSummaryToolTests
{
    [Fact]
    public async Task ClipboardSummaryTool_BlockedWhenSettingDisabled()
    {
        var tool = new ClipboardSummaryTool(() => new ToolsSettings { AllowClipboardRead = false });
        var req = new WindowsToolRequest("test", "clipboard_summary",
            new Dictionary<string, string>(), false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("disabled");
    }
}

// ─── ProcessInspectTool tests ─────────────────────────────────────────────────

public class ProcessInspectToolTests
{
    [Fact]
    public async Task ProcessInspectTool_FiltersSystemProcesses()
    {
        var tool = new ProcessInspectTool();
        var req = new WindowsToolRequest("test", "inspect_processes",
            new Dictionary<string, string>(), false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeTrue();
        // The detail should not contain known system processes
        result.Detail.Should().NotContain("lsass", because: "system processes are filtered");
        result.Detail.Should().NotContain("csrss", because: "system processes are filtered");
    }
}

// ─── OpenProjectTool tests ────────────────────────────────────────────────────

public class OpenProjectToolTests
{
    [Fact]
    public async Task OpenProjectTool_UnknownAlias_ReturnsFailureWithList()
    {
        // Provide one known alias so the failure message lists it
        var tool = new OpenProjectTool(() => new ProjectSettings
        {
            Aliases = [new ProjectAlias("myproject", @"C:\temp", null)]
        });
        var req = new WindowsToolRequest("test", "open_project",
            new Dictionary<string, string> { ["project"] = "unknown-xyz" },
            false, "test", DateTimeOffset.UtcNow);
        var result = await tool.ExecuteAsync(req);
        result.Success.Should().BeFalse();
        result.Summary.Should().Contain("unknown-xyz");
        result.Summary.Should().Contain("myproject");
    }
}

// ─── DesktopMemoryQueryService tests ─────────────────────────────────────────

public class DesktopMemoryQueryTests
{
    private static DesktopMemoryQueryService MakeService(
        IReadOnlyList<WorkSession>? todaySessions = null,
        FocusMetrics? metrics = null)
    {
        var sessionStore = new StubSessionMemoryStore(todaySessions ?? []);
        var usageTracker = new StubAppUsageTracker();
        var focusTracker = new StubFocusSessionTracker(metrics ?? new FocusMetrics(
            DateTimeOffset.UtcNow, TimeSpan.FromMinutes(45), 3, 1, 0.75, FocusState.Focused, "Code", WorkflowCategory.Coding));
        return new DesktopMemoryQueryService(sessionStore, usageTracker, focusTracker);
    }

    [Fact]
    public async Task DesktopMemoryQuery_CodingTimeToday_ReturnsAnswer()
    {
        var codingSession = new WorkSession(
            Guid.NewGuid().ToString(),
            DateTimeOffset.UtcNow.Date.AddHours(9),
            DateTimeOffset.UtcNow.Date.AddHours(11),
            WorkflowCategory.Coding,
            "Code",
            TimeSpan.FromHours(2),
            5,
            0.85,
            "Coding(2h)");

        var svc = MakeService(todaySessions: [codingSession]);
        var answer = await svc.AnswerAsync("how long did I code today?");

        answer.NaturalLanguageAnswer.Should().Contain("2h");
        answer.StructuredData.Should().NotBeNull();
    }

    [Fact]
    public async Task DesktopMemoryQuery_DistractionsToday_ReturnsAnswer()
    {
        var svc = MakeService();
        var answer = await svc.AnswerAsync("what distracted me today?");

        answer.NaturalLanguageAnswer.Should().NotBeNullOrEmpty();
        // When no distractions recorded, should say "No notable distractions"
        answer.NaturalLanguageAnswer.Should().Contain("distraction");
    }

    [Fact]
    public async Task DesktopMemoryQuery_UnknownQuery_ReturnsHelp()
    {
        var svc = MakeService();
        var answer = await svc.AnswerAsync("what is the meaning of life?");

        answer.NaturalLanguageAnswer.Should().Contain("I can answer questions");
    }
}

// ─── WindowsToolBridge tests ──────────────────────────────────────────────────

public class WindowsToolBridgeTests
{
    [Fact]
    public async Task WindowsToolBridge_StaleRequest_DropsWithoutExecution()
    {
        var bridge = new StubMacBridge();
        var tool = new SpyTool();
        var registry = new WindowsToolRegistry(new IWindowsTool[] { tool },
            () => new ToolsSettings { Enabled = true });
        var toolBridge = new WindowsToolBridge(bridge, registry);
        toolBridge.Attach();

        // Send a stale frame (70 seconds old)
        var staleFrame = new Jarvis.Core.Sidecar.SidecarFrame
        {
            Type = Jarvis.Core.Sidecar.SidecarFrameTypes.WindowsToolRequest,
            Id = "stale-1",
            ToolName = "spy_tool",
            At = DateTimeOffset.UtcNow.AddSeconds(-70)   // older than 60s threshold
        };

        bridge.SimulateFrame(staleFrame);

        // Give async handlers a moment
        await Task.Delay(50);

        tool.ExecuteCount.Should().Be(0, because: "stale requests must be dropped");
        toolBridge.Dispose();
    }
}

// ─── DashboardViewModel tests ─────────────────────────────────────────────────

public class DashboardViewModelToolRunTests
{
    [Fact]
    public void DashboardViewModel_RecordToolRun_UpdatesRecentList()
    {
        var vm = new DashboardViewModel();
        vm.RecordToolRun("open_app", true, "Opened chrome", ToolPrivacyImpact.None);

        vm.RecentToolRuns.Should().HaveCount(1);
        vm.RecentToolRuns[0].ToolName.Should().Be("open_app");
        vm.RecentToolRuns[0].Success.Should().BeTrue();
    }

    [Fact]
    public void DashboardViewModel_RecentToolRuns_BoundedAtTen()
    {
        var vm = new DashboardViewModel();
        for (var i = 0; i < 15; i++)
            vm.RecordToolRun($"tool_{i}", true, $"Summary {i}", ToolPrivacyImpact.None);

        vm.RecentToolRuns.Should().HaveCount(10, because: "history is bounded at 10 entries");
    }
}

// ─── Stubs ────────────────────────────────────────────────────────────────────

internal sealed class StubSessionMemoryStore : ISessionMemoryStore
{
    private readonly IReadOnlyList<WorkSession> _today;
    public StubSessionMemoryStore(IReadOnlyList<WorkSession> today) => _today = today;
    public Task<IReadOnlyList<WorkSession>> GetTodayAsync() => Task.FromResult(_today);
    public Task<IReadOnlyList<WorkSession>> GetRecentAsync(int days = 7) => Task.FromResult(_today);
    public Task SaveSessionAsync(WorkSession session) => Task.CompletedTask;
    public Task ClearAsync() => Task.CompletedTask;
    public Task<long> GetStoreSizeAsync() => Task.FromResult(0L);
}

#pragma warning disable CS0067 // test stubs implement interface events that are never raised
internal sealed class StubAppUsageTracker : IAppUsageTracker
{
    public IReadOnlyList<AppUsageEntry> GetRecent(int maxEntries = 10) => [];
    public event EventHandler<AppUsageEntry>? EntryAdded;
}

internal sealed class StubFocusSessionTracker : IFocusSessionTracker
{
    public StubFocusSessionTracker(FocusMetrics metrics) => Current = metrics;
    public FocusMetrics Current { get; }
    public event EventHandler<FocusMetrics>? MetricsChanged;
    public Task StartAsync(CancellationToken ct = default) => Task.CompletedTask;
    public Task StopAsync(CancellationToken ct = default) => Task.CompletedTask;
}

internal sealed class StubMacBridge : Jarvis.Core.Sidecar.IMacBridgeCoordinator
{
    public event EventHandler<Jarvis.Core.Sidecar.SidecarFrame>? FrameReceived;
    public event EventHandler<Jarvis.Core.Sidecar.BridgeStatus>? StatusChanged;

    public Jarvis.Core.Sidecar.BridgeStatus Status =>
        new(Jarvis.Core.Sidecar.BridgeState.Connected, DateTimeOffset.UtcNow, 0, null, null);

    public void SimulateFrame(Jarvis.Core.Sidecar.SidecarFrame frame) =>
        FrameReceived?.Invoke(this, frame);

    public Task<bool> SendAsync(Jarvis.Core.Sidecar.SidecarFrame frame,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(true);

    public Task StartAsync(CancellationToken ct = default) => Task.CompletedTask;
    public Task StopAsync(CancellationToken ct = default) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

internal sealed class SpyTool : IWindowsTool
{
    public int ExecuteCount;
    public string Name => "spy_tool";
    public IReadOnlyList<string> Aliases => [];
    public string Description => "Test spy tool";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Safe;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        Interlocked.Increment(ref ExecuteCount);
        return Task.FromResult(new WindowsToolResult(true, "ok", null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow));
    }
}
