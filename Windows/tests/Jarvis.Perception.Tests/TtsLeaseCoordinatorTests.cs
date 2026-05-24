using FluentAssertions;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class TtsLeaseCoordinatorTests
{
    [Fact]
    public void Default_owner_is_none()
    {
        var coord = new TtsLeaseCoordinator(new FakeBridge());
        coord.Current.Owner.Should().Be(SpeakerOwner.None);
    }

    [Fact]
    public void RequestLocalLease_does_not_self_grant_but_sends_request()
    {
        var bridge = new FakeBridge();
        var coord = new TtsLeaseCoordinator(bridge);
        var granted = coord.RequestLocalLease("local say");
        granted.Should().BeFalse();
        coord.Current.Owner.Should().Be(SpeakerOwner.None);
        bridge.Sent.Should().Contain(f => f.Type == SidecarFrameTypes.LeaseRequest && f.Reason == "local say");
    }

    [Fact]
    public void LeaseGrant_inbound_transitions_to_windows()
    {
        var coord = new TtsLeaseCoordinator(new FakeBridge());
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseGrant, LeaseToken = "T", Reason = "you're up" });
        coord.Current.Owner.Should().Be(SpeakerOwner.Windows);
        coord.Current.Token.Should().Be("T");
    }

    [Fact]
    public void LeaseRevoke_inbound_resets_to_none()
    {
        var coord = new TtsLeaseCoordinator(new FakeBridge());
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseGrant, LeaseToken = "T" });
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseRevoke });
        coord.Current.Owner.Should().Be(SpeakerOwner.None);
    }

    [Fact]
    public void Mac_speaker_active_takes_ownership()
    {
        var coord = new TtsLeaseCoordinator(new FakeBridge());
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.SpeakerActive, Source = "mac" });
        coord.Current.Owner.Should().Be(SpeakerOwner.Mac);
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.SpeakerSilent, Source = "mac" });
        coord.Current.Owner.Should().Be(SpeakerOwner.None);
    }

    [Fact]
    public void NotifyLocalSpeaking_without_lease_emits_no_frame_and_warns()
    {
        var bridge = new FakeBridge();
        var coord = new TtsLeaseCoordinator(bridge);
        coord.NotifyLocalSpeaking(true);
        bridge.Sent.Should().NotContain(f => f.Type == SidecarFrameTypes.SpeakerActive);
    }

    [Fact]
    public void NotifyLocalSpeaking_with_lease_emits_speaker_frame()
    {
        var bridge = new FakeBridge();
        var coord = new TtsLeaseCoordinator(bridge);
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseGrant, LeaseToken = "T" });
        coord.NotifyLocalSpeaking(true);
        bridge.Sent.Should().ContainSingle(f => f.Type == SidecarFrameTypes.SpeakerActive && f.Source == "windows");
        coord.NotifyLocalSpeaking(false);
        bridge.Sent.Should().ContainSingle(f => f.Type == SidecarFrameTypes.SpeakerSilent);
        coord.Current.Owner.Should().Be(SpeakerOwner.None);
    }

    [Fact]
    public void Changed_event_fires_on_transition_not_on_repeat()
    {
        var coord = new TtsLeaseCoordinator(new FakeBridge());
        var count = 0;
        coord.Changed += (_, _) => count++;
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseGrant });
        coord.ApplyInbound(new SidecarFrame { Type = SidecarFrameTypes.LeaseGrant }); // identical state
        count.Should().Be(1);
    }

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public List<SidecarFrame> Sent { get; } = new();
        public BridgeStatus Status => new(BridgeState.Connected, DateTimeOffset.UtcNow, 0, null, null);
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived { add { } remove { } }
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) { Sent.Add(f); return Task.FromResult(true); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
