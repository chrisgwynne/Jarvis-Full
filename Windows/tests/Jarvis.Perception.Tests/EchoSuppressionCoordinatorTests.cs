using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class EchoSuppressionCoordinatorTests
{
    private static EchoSuppressionCoordinator Make(double strength = 0.7) =>
        new(() => new SidecarSettings { EchoSuppressionStrength = strength });

    [Fact]
    public void Speaker_active_suppresses_everything()
    {
        var c = Make();
        c.NotifySpeaker(SpeakerOwner.Mac, "any text", starting: true);
        c.ShouldSuppress("totally unrelated").Should().Be(SuppressionReason.SpeakerActive);
    }

    [Fact]
    public void Privacy_mode_suppresses_everything()
    {
        var c = Make();
        c.SetPrivacyMode(true);
        c.ShouldSuppress("hello").Should().Be(SuppressionReason.PrivacyMode);
    }

    [Fact]
    public void Post_speech_cooldown_suppresses_briefly()
    {
        var c = Make();
        c.NotifySpeaker(SpeakerOwner.Mac, "hi there", starting: true);
        c.NotifySpeaker(SpeakerOwner.Mac, "hi there", starting: false);
        c.ShouldSuppress("anything").Should().Be(SuppressionReason.PostSpeechCooldown);
    }

    [Fact]
    public void Echo_similarity_suppresses_near_duplicate_of_recent_speech()
    {
        var c = Make(strength: 0.5);
        c.NotifySpeaker(SpeakerOwner.Mac, "click the save button", starting: true);
        c.NotifySpeaker(SpeakerOwner.Mac, "click the save button", starting: false);
        Thread.Sleep(800); // exceed cooldown
        // Almost the same transcript leaks back through the mic — must be suppressed.
        c.ShouldSuppress("click the save button please").Should().Be(SuppressionReason.EchoSimilarity);
    }

    [Fact]
    public void Unrelated_transcript_passes_after_cooldown()
    {
        var c = Make();
        c.NotifySpeaker(SpeakerOwner.Mac, "click the save button", starting: true);
        c.NotifySpeaker(SpeakerOwner.Mac, "click the save button", starting: false);
        Thread.Sleep(800);
        c.ShouldSuppress("what's the weather like").Should().Be(SuppressionReason.None);
    }

    [Fact]
    public void Empty_transcript_is_none()
    {
        var c = Make();
        c.ShouldSuppress("").Should().Be(SuppressionReason.None);
    }

    [Fact]
    public void Jaccard_similarity_computes_correctly()
    {
        EchoSuppressionCoordinator.Similarity("save the document", "save document").Should().BeApproximately(2.0/3.0, 0.001);
        EchoSuppressionCoordinator.Similarity("foo bar", "qux quux").Should().Be(0);
        EchoSuppressionCoordinator.Similarity("foo", "foo").Should().Be(1.0);
    }
}
