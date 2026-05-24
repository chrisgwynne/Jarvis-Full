using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class EchoSuppressionV2Tests
{
    private static EchoSuppressionCoordinator Make(double strength = 0.7) =>
        new(() => new SidecarSettings { EchoSuppressionStrength = strength });

    [Fact]
    public void Playback_active_hard_suppresses_everything()
    {
        var c = Make();
        c.NotifyPlaybackActive(true);
        c.ShouldSuppress("any partial transcript").Should().Be(SuppressionReason.PlaybackActive);
    }

    [Fact]
    public void Playback_stop_falls_into_cooldown()
    {
        var c = Make();
        c.NotifyPlaybackActive(true);
        c.NotifyPlaybackActive(false);
        c.ShouldSuppress("anything").Should().Be(SuppressionReason.PostSpeechCooldown);
    }

    [Fact]
    public void Wake_word_suppressed_during_playback()
    {
        var c = Make();
        c.NotifyPlaybackActive(true);
        c.ShouldSuppressWakeWord().Should().BeTrue();
        c.NotifyPlaybackActive(false);
        // Cooldown still suppresses for ~700ms
        c.ShouldSuppressWakeWord().Should().BeTrue();
    }

    [Fact]
    public void Wake_word_passes_in_idle_state()
    {
        var c = Make();
        c.ShouldSuppressWakeWord().Should().BeFalse();
    }

    [Fact]
    public void Duplicate_transcript_within_window_is_flagged()
    {
        var c = Make();
        c.ShouldSuppress("set timer for ten minutes").Should().Be(SuppressionReason.None);
        c.ShouldSuppress("set timer for ten minutes").Should().Be(SuppressionReason.Duplicate);
    }

    [Fact]
    public void IsLikelyEcho_matches_recent_speech()
    {
        var c = Make(strength: 0.7);
        c.NotifySpeaker(SpeakerOwner.Mac, "click the save button to commit", starting: true);
        c.IsLikelyEcho("click the save button").Should().BeTrue();
        c.IsLikelyEcho("what's the time").Should().BeFalse();
    }
}
