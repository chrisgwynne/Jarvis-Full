using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class PartialTranscriptCoordinatorTests
{
    private static (PartialTranscriptCoordinator coord, FakeBridge bridge, FakeProvider provider, EchoSuppressionCoordinator echo) Build()
    {
        var bridge = new FakeBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { EchoSuppressionStrength = 0.7 });
        var coord = new PartialTranscriptCoordinator(bridge, echo, new AudioDiagnostics());
        var provider = new FakeProvider();
        coord.Attach(provider);
        return (coord, bridge, provider, echo);
    }

    [Fact]
    public void Partials_forward_to_bridge_as_transcript_partial_frames()
    {
        var (coord, bridge, provider, _) = Build();
        provider.EmitPartial("hello wor");
        provider.EmitPartial("hello world");

        bridge.Frames.Should().HaveCount(2);
        bridge.Frames.Should().AllSatisfy(f => f.Type.Should().Be(SidecarFrameTypes.TranscriptPartial));
        coord.PartialsSent.Should().Be(2);
    }

    [Fact]
    public void Final_forwards_and_resets_session()
    {
        var (coord, bridge, provider, _) = Build();
        provider.EmitPartial("good morn");
        provider.EmitFinal("good morning");
        bridge.Frames[1].Type.Should().Be(SidecarFrameTypes.TranscriptFinal);
        bridge.Frames[1].IsFinal.Should().Be(true);
        coord.FinalsSent.Should().Be(1);
    }

    [Fact]
    public void Suppressed_partials_are_counted_but_not_forwarded()
    {
        var (coord, bridge, provider, echo) = Build();
        echo.SetPrivacyMode(true);
        provider.EmitPartial("any text");
        bridge.Frames.Should().BeEmpty();
        coord.SuppressedPartials.Should().Be(1);
    }

    [Fact]
    public void Duplicate_finals_within_window_are_suppressed()
    {
        var (coord, bridge, provider, _) = Build();
        provider.EmitFinal("save the file");
        provider.EmitFinal("save the file"); // immediate duplicate
        coord.FinalsSent.Should().Be(1);
        coord.SuppressedFinals.Should().Be(1);
        bridge.Frames.Count(f => f.Type == SidecarFrameTypes.TranscriptFinal).Should().Be(1);
    }

    [Fact]
    public void Detach_stops_forwarding()
    {
        var (coord, bridge, provider, _) = Build();
        coord.Detach();
        provider.EmitPartial("ignored");
        bridge.Frames.Should().BeEmpty();
    }

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public List<SidecarFrame> Frames { get; } = new();
        public BridgeStatus Status { get; } = new(BridgeState.Connected, DateTimeOffset.UtcNow, 0, null, null);
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived { add { } remove { } }
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) { Frames.Add(f); return Task.FromResult(true); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeProvider : ISpeechRecognitionProvider
    {
        public bool IsRecognizing => true;
        public event EventHandler<TranscriptEvent>? Partial;
        public event EventHandler<TranscriptEvent>? Final;
        public event EventHandler<bool>? RecognizingChanged { add { } remove { } }
        public Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        public void EmitPartial(string text) => Partial?.Invoke(this,
            new TranscriptEvent("sess", text, 0.5, IsFinal: false, DateTimeOffset.UtcNow));
        public void EmitFinal(string text) => Final?.Invoke(this,
            new TranscriptEvent("sess", text, 0.9, IsFinal: true, DateTimeOffset.UtcNow));
    }
}
