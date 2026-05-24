using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class WakeAliasTranscriptTests
{
    [Fact]
    public void Transcript_frames_carry_wake_alias_and_device_id()
    {
        var bridge = new RecordingBridge();
        var settings = new SidecarSettings { LocalWakeAlias = "Pebble", DeviceName = "Office desktop" };
        var echo = new EchoSuppressionCoordinator(() => settings);
        var coord = new PartialTranscriptCoordinator(bridge, echo, new AudioDiagnostics(), null, () => settings);
        var provider = new FakeProvider();
        coord.Attach(provider);

        provider.EmitPartial("turn on the lights");
        provider.EmitFinal("turn on the lights please");

        bridge.Frames.Should().HaveCount(2);
        bridge.Frames[0].WakeAlias.Should().Be("Pebble");
        bridge.Frames[0].CaptureDeviceId.Should().Be("Office desktop");
        bridge.Frames[1].WakeAlias.Should().Be("Pebble");
        bridge.Frames[1].CaptureDeviceId.Should().Be("Office desktop");
    }

    [Fact]
    public void Wake_alias_disabled_omits_alias_but_keeps_device_id()
    {
        var bridge = new RecordingBridge();
        var settings = new SidecarSettings
        {
            WakeAliasEnabled = false,
            LocalWakeAlias = "Pebble",
            DeviceName = "Office desktop"
        };
        var echo = new EchoSuppressionCoordinator(() => settings);
        var coord = new PartialTranscriptCoordinator(bridge, echo, new AudioDiagnostics(), null, () => settings);
        var provider = new FakeProvider();
        coord.Attach(provider);

        provider.EmitPartial("hello");

        bridge.Frames[0].WakeAlias.Should().BeNull();
        bridge.Frames[0].CaptureDeviceId.Should().Be("Office desktop");
    }

    [Fact]
    public void No_settings_means_no_attribution()
    {
        var bridge = new RecordingBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings());
        var coord = new PartialTranscriptCoordinator(bridge, echo, new AudioDiagnostics());
        var provider = new FakeProvider();
        coord.Attach(provider);

        provider.EmitPartial("anything");

        bridge.Frames[0].WakeAlias.Should().BeNull();
        bridge.Frames[0].CaptureDeviceId.Should().BeNull();
    }

    private sealed class RecordingBridge : IMacBridgeCoordinator
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
