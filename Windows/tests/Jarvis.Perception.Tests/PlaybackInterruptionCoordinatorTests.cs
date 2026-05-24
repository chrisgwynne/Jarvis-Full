using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class PlaybackInterruptionCoordinatorTests
{
    [Fact]
    public async Task User_speech_during_playback_stops_tts_and_notifies_mac()
    {
        var bridge = new FakeBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { EchoSuppressionStrength = 0.7 });
        var lease = new FakeLease();
        var coord = new PlaybackInterruptionCoordinator(bridge, echo, lease, new AudioDiagnostics());

        var provider = new FakeProvider();
        var tts = new FakeTts();
        coord.Attach(provider, tts);

        tts.IsSpeaking = true;
        coord.NotifyPlaybackChanged(true);

        // Allow the 200ms grace window to pass so a real interruption can register.
        await Task.Delay(250);

        provider.EmitPartial("no not that");

        coord.Interruptions.Should().Be(1);
        tts.StopCalled.Should().BeTrue();
        bridge.Frames.Should().Contain(f =>
            f.Type == SidecarFrameTypes.SpeakerSilent && f.Reason == "interrupted");
    }

    [Fact]
    public async Task Speech_that_looks_like_self_echo_does_not_interrupt()
    {
        var bridge = new FakeBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { EchoSuppressionStrength = 0.7 });
        var lease = new FakeLease();
        var coord = new PlaybackInterruptionCoordinator(bridge, echo, lease, new AudioDiagnostics());

        var provider = new FakeProvider();
        var tts = new FakeTts();
        coord.Attach(provider, tts);

        // Mark the assistant as having just said this text.
        echo.NotifySpeaker(SpeakerOwner.Windows, "click the save button", starting: true);

        tts.IsSpeaking = true;
        coord.NotifyPlaybackChanged(true);
        await Task.Delay(250);

        // STT picks up the very text the assistant is currently saying — must NOT interrupt.
        provider.EmitPartial("click the save button");

        coord.Interruptions.Should().Be(0);
        tts.StopCalled.Should().BeFalse();
    }

    [Fact]
    public async Task Interruption_in_first_200ms_is_ignored()
    {
        var bridge = new FakeBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { EchoSuppressionStrength = 0.7 });
        var lease = new FakeLease();
        var coord = new PlaybackInterruptionCoordinator(bridge, echo, lease, new AudioDiagnostics());

        var provider = new FakeProvider();
        var tts = new FakeTts { IsSpeaking = true };
        coord.Attach(provider, tts);
        coord.NotifyPlaybackChanged(true);
        // Immediately fire a partial within the grace window.
        provider.EmitPartial("real user speech");
        coord.Interruptions.Should().Be(0);
        await Task.CompletedTask;
    }

    [Fact]
    public void Speech_when_tts_silent_does_nothing()
    {
        var bridge = new FakeBridge();
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { EchoSuppressionStrength = 0.7 });
        var lease = new FakeLease();
        var coord = new PlaybackInterruptionCoordinator(bridge, echo, lease, new AudioDiagnostics());
        var provider = new FakeProvider();
        var tts = new FakeTts { IsSpeaking = false };
        coord.Attach(provider, tts);
        provider.EmitPartial("hello");
        coord.Interruptions.Should().Be(0);
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

    private sealed class FakeLease : ITtsLeaseCoordinator
    {
        public LeaseState Current { get; private set; } = new(SpeakerOwner.Windows, "tok", null, null);
        public event EventHandler<LeaseState>? Changed { add { } remove { } }
        public bool RequestLocalLease(string reason) => true;
        public void ApplyInbound(SidecarFrame frame) { }
        public void NotifyLocalSpeaking(bool speaking) { }
    }

    private sealed class FakeProvider : ISpeechRecognitionProvider
    {
        public bool IsRecognizing => true;
        public event EventHandler<TranscriptEvent>? Partial;
        public event EventHandler<TranscriptEvent>? Final { add { } remove { } }
        public event EventHandler<bool>? RecognizingChanged { add { } remove { } }
        public Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void EmitPartial(string text) => Partial?.Invoke(this,
            new TranscriptEvent("sess", text, 0.5, IsFinal: false, DateTimeOffset.UtcNow));
    }

    private sealed class FakeTts : ILocalTtsService
    {
        public bool IsSpeaking { get; set; }
        public bool StopCalled { get; private set; }
        public Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default) => Task.FromResult(true);
        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            StopCalled = true;
            IsSpeaking = false;
            return Task.CompletedTask;
        }
    }
}
