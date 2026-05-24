using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class RemoteExecutionBridgeTests
{
    [Fact]
    public void Parses_focus_window_intent()
    {
        var intent = RemoteExecutionBridge.ParseIntent("window.focus", "{\"process\":\"notepad\"}");
        intent.Should().BeOfType<FocusWindowIntent>();
        ((FocusWindowIntent)intent!).Process.Should().Be("notepad");
    }

    [Fact]
    public void Parses_mouse_click_with_button_and_count()
    {
        var intent = RemoteExecutionBridge.ParseIntent("mouse.click",
            "{\"x\":100,\"y\":200,\"button\":\"Right\",\"count\":2}");
        var click = (ClickIntent)intent!;
        click.X.Should().Be(100);
        click.Y.Should().Be(200);
        click.Button.Should().Be(MouseButtonKind.Right);
        click.Count.Should().Be(2);
    }

    [Fact]
    public void Parses_browser_navigate_with_url()
    {
        var intent = RemoteExecutionBridge.ParseIntent("browser.navigate",
            "{\"url\":\"https://example.com\"}");
        intent.Should().BeOfType<BrowserNavigateIntent>();
        ((BrowserNavigateIntent)intent!).Url.Should().Be("https://example.com");
    }

    [Fact]
    public void Unsupported_kind_returns_null()
    {
        RemoteExecutionBridge.ParseIntent("nope.nope", "{}").Should().BeNull();
    }

    [Fact]
    public void Empty_inputs_return_null()
    {
        RemoteExecutionBridge.ParseIntent(null, null).Should().BeNull();
        RemoteExecutionBridge.ParseIntent("", "").Should().BeNull();
    }

    [Fact]
    public async Task Executor_results_drive_ack_outcome()
    {
        var bridge = new FakeBridge();
        var executor = new FakeExecutor(AutomationOutcome.Succeeded);
        var rem = new RemoteExecutionBridge(bridge, executor);
        rem.Attach();
        bridge.RaiseInbound(new SidecarFrame
        {
            Type = SidecarFrameTypes.ExecuteIntent,
            CommandId = "c1",
            IntentKind = "window.focus",
            IntentJson = "{\"process\":\"notepad\"}"
        });
        await Task.Delay(50);
        bridge.Sent.Should().ContainSingle(f => f.Type == SidecarFrameTypes.ExecuteAck && f.Outcome == "Succeeded" && f.CommandId == "c1");
        rem.Accepted.Should().Be(1);
        rem.Failed.Should().Be(0);
    }

    [Fact]
    public async Task Denied_outcome_increments_failed_counter()
    {
        var bridge = new FakeBridge();
        var executor = new FakeExecutor(AutomationOutcome.DeniedByPolicy);
        var rem = new RemoteExecutionBridge(bridge, executor);
        rem.Attach();
        bridge.RaiseInbound(new SidecarFrame
        {
            Type = SidecarFrameTypes.ExecuteIntent,
            CommandId = "c2",
            IntentKind = "keyboard.type",
            IntentJson = "{\"text\":\"hello\"}"
        });
        await Task.Delay(50);
        rem.Failed.Should().Be(1);
        bridge.Sent.Last(f => f.Type == SidecarFrameTypes.ExecuteAck).Outcome.Should().Be("DeniedByPolicy");
    }

    [Fact]
    public async Task Unknown_intent_kind_acks_with_failure_and_increments_rejected()
    {
        var bridge = new FakeBridge();
        var executor = new FakeExecutor(AutomationOutcome.Succeeded);
        var rem = new RemoteExecutionBridge(bridge, executor);
        rem.Attach();
        bridge.RaiseInbound(new SidecarFrame
        {
            Type = SidecarFrameTypes.ExecuteIntent,
            CommandId = "c3",
            IntentKind = "totally.fake",
            IntentJson = "{}"
        });
        await Task.Delay(50);
        rem.Rejected.Should().Be(1);
        bridge.Sent.Last(f => f.Type == SidecarFrameTypes.ExecuteAck).Outcome.Should().Be("Failed");
    }

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public List<SidecarFrame> Sent { get; } = new();
        public BridgeStatus Status => new(BridgeState.Connected, DateTimeOffset.UtcNow, 0, null, null);
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived;
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) { Sent.Add(f); return Task.FromResult(true); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void RaiseInbound(SidecarFrame f) => FrameReceived?.Invoke(this, f);
    }

    private sealed class FakeExecutor : IAutomationExecutor
    {
        private readonly AutomationOutcome _outcome;
        public FakeExecutor(AutomationOutcome outcome) { _outcome = outcome; }
        public AutomationPlan DryRun(AutomationIntent intent) =>
            new("dry", Array.Empty<string>(), null, null, new SafetyDecision(SafetyTier.Approve, "fake"));
        public Task<AutomationResult> ExecuteAsync(AutomationIntent intent, CancellationToken cancellationToken = default) =>
            Task.FromResult(new AutomationResult(intent, DryRun(intent), _outcome,
                _outcome == AutomationOutcome.Succeeded ? null : "blocked",
                null, DateTimeOffset.UtcNow, TimeSpan.FromMilliseconds(1)));
    }
}
