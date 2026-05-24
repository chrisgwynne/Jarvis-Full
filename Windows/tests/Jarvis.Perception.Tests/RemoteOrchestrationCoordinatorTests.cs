using FluentAssertions;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class RemoteOrchestrationCoordinatorTests
{
    [Fact]
    public void Speak_frame_raises_event_and_increments_counter()
    {
        var bridge = new FakeBridge();
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        string? heard = null;
        coord.SpeakRequested += (_, text) => heard = text;

        bridge.Receive(new SidecarFrame { Type = SidecarFrameTypes.OrchestrateSpeak, Text = "go ahead" });
        heard.Should().Be("go ahead");
        coord.SpeakCommands.Should().Be(1);
    }

    [Fact]
    public void Silent_frame_raises_event_and_increments_counter()
    {
        var bridge = new FakeBridge();
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        var fired = 0;
        coord.SilenceRequested += (_, _) => fired++;

        bridge.Receive(new SidecarFrame { Type = SidecarFrameTypes.OrchestrateSilent, Reason = "mac takes turn" });
        fired.Should().Be(1);
        coord.SilenceCommands.Should().Be(1);
    }

    [Fact]
    public void Proactive_notify_routes_with_payload()
    {
        var bridge = new FakeBridge();
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        ProactiveNotice? captured = null;
        coord.ProactiveReceived += (_, n) => captured = n;

        bridge.Receive(new SidecarFrame
        {
            Type = SidecarFrameTypes.ProactiveNotify,
            Reason = "Build failed",
            Text = "main #1481 — 2 tests broke",
            Source = "github",
            At = DateTimeOffset.UtcNow
        });
        captured.Should().NotBeNull();
        captured!.Title.Should().Be("Build failed");
        captured.Source.Should().Be("github");
        coord.ProactiveNotifications.Should().Be(1);
    }

    [Fact]
    public void Unrelated_frame_is_ignored()
    {
        var bridge = new FakeBridge();
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        var any = 0;
        coord.SpeakRequested += (_, _) => any++;
        coord.SilenceRequested += (_, _) => any++;
        coord.ProactiveReceived += (_, _) => any++;

        bridge.Receive(new SidecarFrame { Type = SidecarFrameTypes.Heartbeat });
        any.Should().Be(0);
    }

    [Fact]
    public void Dispose_unsubscribes_so_no_more_events_after()
    {
        var bridge = new FakeBridge();
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        var fired = 0;
        coord.SpeakRequested += (_, _) => fired++;
        coord.Dispose();
        bridge.Receive(new SidecarFrame { Type = SidecarFrameTypes.OrchestrateSpeak });
        fired.Should().Be(0);
    }

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public BridgeStatus Status { get; } = new(BridgeState.Connected, DateTimeOffset.UtcNow, 0, null, null);
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived;
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) => Task.FromResult(true);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Receive(SidecarFrame f) => FrameReceived?.Invoke(this, f);
    }
}
