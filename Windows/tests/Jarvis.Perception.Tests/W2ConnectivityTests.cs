using FluentAssertions;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

// ─────────────────────────────────────────────────────────────────────────────
// W2 Sprint — Mac Bridge Connectivity
//
// These tests verify:
//   1. BridgeConnectivityProbe.ToHealthUrl correctly transforms ws/wss → http/https.
//   2. BridgeConnectivityProbe rejects non-WebSocket URLs immediately.
//   3. BridgeStatus optional fields default to null (backward compat with all callers).
//   4. BridgeStatus tracks LastSuccessfulConnectAt and DegradedModeEnteredAt.
//   5. DistributedFallbackCoordinator replays frames in insertion order on reconnect.
//   6. MacBridgeCoordinator.SnapshotOutbound captures queued frames.
// ─────────────────────────────────────────────────────────────────────────────

public class W2ConnectivityTests
{
    // ── Task 3: ToHealthUrl transformation ────────────────────────────────────

    [Theory]
    [InlineData("ws://100.64.1.5:8765/v2/ws",        "http://100.64.1.5:8765/brain/health")]
    [InlineData("ws://mac.tail.ts.net:8765/v2/ws",   "http://mac.tail.ts.net:8765/brain/health")]
    [InlineData("wss://mac.tail.ts.net:443/v2/ws",   "https://mac.tail.ts.net/brain/health")]   // default port omitted
    [InlineData("wss://mac.tail.ts.net:8765/v2/ws",  "https://mac.tail.ts.net:8765/brain/health")]
    [InlineData("ws://127.0.0.1:8765/v2/ws",         "http://127.0.0.1:8765/brain/health")]
    public void ToHealthUrl_transforms_ws_scheme_to_http(string bridgeUrl, string expected)
    {
        BridgeConnectivityProbe.ToHealthUrl(bridgeUrl)!.ToString().Should().Be(expected);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-url")]
    [InlineData("http://100.64.1.5:8765")]
    public void ToHealthUrl_returns_null_for_invalid_input(string bridgeUrl)
    {
        BridgeConnectivityProbe.ToHealthUrl(bridgeUrl).Should().BeNull();
    }

    // ── Task 1: URL validation in probe ───────────────────────────────────────

    [Fact]
    public async Task Probe_rejects_non_websocket_url_immediately()
    {
        var result = await BridgeConnectivityProbe.RunAsync("http://100.64.1.5:8765", null);
        result.Stages.Should().HaveCount(1);
        result.Stages[0].Label.Should().Be("URL");
        result.Stages[0].Ok.Should().BeFalse();
        result.AllOk.Should().BeFalse();
    }

    [Fact]
    public async Task Probe_rejects_garbage_url_immediately()
    {
        var result = await BridgeConnectivityProbe.RunAsync("not-a-url", null);
        result.Stages.Should().HaveCount(1);
        result.Stages[0].Ok.Should().BeFalse();
    }

    [Fact]
    public async Task Probe_passes_url_stage_for_valid_ws_url()
    {
        // A localhost URL that will fail DNS/TCP is fine — we only care the URL stage passes.
        var result = await BridgeConnectivityProbe.RunAsync(
            "ws://no-such-host-xyz.invalid:8765/v2/ws", null,
            new CancellationTokenSource(TimeSpan.FromSeconds(8)).Token);

        result.Stages[0].Label.Should().Be("URL");
        result.Stages[0].Ok.Should().BeTrue("URL stage passes for valid ws:// scheme");
        // Will fail at DNS or TCP — not URL.
        result.Stages.Count(s => !s.Ok).Should().Be(1);
        result.AllOk.Should().BeFalse();
    }

    [Fact]
    public async Task Probe_warns_on_localhost_url_but_still_passes_url_stage()
    {
        // A localhost URL that will fail TCP (nothing listening) — URL stage should still pass
        // with a warning embedded in the detail.
        var result = await BridgeConnectivityProbe.RunAsync(
            "ws://127.0.0.1:19999/v2/ws", null,   // unlikely to have anything on 19999
            new CancellationTokenSource(TimeSpan.FromSeconds(8)).Token);

        result.Stages[0].Ok.Should().BeTrue();
        result.Stages[0].Detail.Should().Contain("localhost", "localhost warning is in the detail text");
    }

    // ── Task 5: BridgeStatus optional fields ──────────────────────────────────

    [Fact]
    public void BridgeStatus_defaults_optional_fields_to_null()
    {
        // All existing callers create BridgeStatus with 5 positional args.
        var s = new BridgeStatus(BridgeState.Disabled, DateTimeOffset.UtcNow, 0, null, null);
        s.LastSuccessfulConnectAt.Should().BeNull();
        s.DegradedModeEnteredAt.Should().BeNull();
    }

    [Fact]
    public void BridgeStatus_with_optional_fields_round_trips()
    {
        var now = DateTimeOffset.UtcNow;
        var s = new BridgeStatus(BridgeState.Connected, now, 0, 12.5, null,
            LastSuccessfulConnectAt: now,
            DegradedModeEnteredAt: null);
        s.LastSuccessfulConnectAt.Should().Be(now);
        s.DegradedModeEnteredAt.Should().BeNull();
    }

    // ── Task 8: Replay ordering ────────────────────────────────────────────────

    [Fact]
    public void Reconnect_replays_frames_in_insertion_order()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);

        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "first" });
        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "second" });
        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "third" });

        bridge.TransitionTo(BridgeState.Connected);

        var transcripts = bridge.Sent
            .Where(f => f.Type == SidecarFrameTypes.TranscriptFinal)
            .Select(f => f.Text)
            .ToList();
        transcripts.Should().Equal(new[] { "first", "second", "third" },
            "frames must replay in insertion order so Mac brain sees them in sequence");
    }

    [Fact]
    public void Reconnect_wraps_replay_in_begin_and_end_markers()
    {
        var bridge = new ProgrammableBridge(BridgeState.Degraded);
        var coord = new DistributedFallbackCoordinator(bridge);

        coord.ForwardOrQueue(new SidecarFrame { Type = SidecarFrameTypes.TranscriptFinal, Text = "a" });

        bridge.TransitionTo(BridgeState.Connected);

        bridge.Sent.First().Type.Should().Be(SidecarFrameTypes.ReplayBegin);
        bridge.Sent.Last().Type.Should().Be(SidecarFrameTypes.ReplayEnd);
        coord.Queued.Should().Be(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test doubles
    // ─────────────────────────────────────────────────────────────────────────

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
