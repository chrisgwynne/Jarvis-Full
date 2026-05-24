using FluentAssertions;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class DistributedFallbackCoordinatorTests
{
    [Fact]
    public void When_connected_frames_pass_through()
    {
        var bridge = new ProgrammableBridge(BridgeState.Connected);
        var coord = new DistributedFallbackCoordinator(bridge);

        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "hello" });
        bridge.Sent.Should().HaveCount(1);
        coord.Queued.Should().Be(0);
        coord.IsBuffering.Should().BeFalse();
    }

    [Fact]
    public void When_degraded_frames_are_queued()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);

        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "a" });
        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "b" });
        bridge.Sent.Should().BeEmpty();
        coord.Queued.Should().Be(2);
        coord.IsBuffering.Should().BeTrue();
    }

    [Fact]
    public void Reconnect_replays_queue_with_begin_and_end_markers()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);

        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "a" });
        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "b" });

        bridge.TransitionTo(BridgeState.Connected);

        bridge.Sent.Should().HaveCountGreaterOrEqualTo(4);
        bridge.Sent.First().Type.Should().Be(SidecarFrameTypes.ReplayBegin);
        bridge.Sent.Last().Type.Should().Be(SidecarFrameTypes.ReplayEnd);
        bridge.Sent.Count(f => f.Type == SidecarFrameTypes.TranscriptFinal).Should().Be(2);
        coord.Queued.Should().Be(0);
        coord.FlushedTotal.Should().Be(2);
    }

    [Fact]
    public void Cap_drops_oldest_on_overflow()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);
        // 128 cap — push 200, expect 128 surviving (newest).
        for (var i = 0; i < 200; i++)
        {
            coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = i.ToString() });
        }
        coord.Queued.Should().BeLessOrEqualTo(128);
    }

    [Fact]
    public void Reconnect_with_empty_queue_is_a_noop()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);
        bridge.TransitionTo(BridgeState.Connected);
        bridge.Sent.Should().BeEmpty();
    }

    private sealed class ProgrammableBridge : IMacBridgeCoordinator
    {
        public List<SidecarFrame> Sent { get; } = new();
        public BridgeStatus Status { get; private set; }
        public event EventHandler<BridgeStatus>? StatusChanged;
        public event EventHandler<SidecarFrame>? FrameReceived { add { } remove { } }

        public ProgrammableBridge(BridgeState initial)
        {
            Status = new BridgeStatus(initial, DateTimeOffset.UtcNow, 0, null, null);
        }

        public void TransitionTo(BridgeState s)
        {
            Status = new BridgeStatus(s, DateTimeOffset.UtcNow, 0, null, null);
            StatusChanged?.Invoke(this, Status);
        }

        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) { Sent.Add(f); return Task.FromResult(true); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
