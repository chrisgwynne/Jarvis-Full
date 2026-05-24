using FluentAssertions;
using Jarvis.Core.Settings;
using Xunit;

namespace Jarvis.Core.Tests;

public class WakeAliasTests
{
    [Fact]
    public void Default_alias_is_Pebble_not_Jarvis_so_nearby_brain_doesnt_double_wake()
    {
        var s = new SidecarSettings();
        s.LocalWakeAlias.Should().Be("Pebble");
        s.AssistantIdentityName.Should().Be("Jarvis");
        s.EffectiveWakeAlias.Should().Be("Pebble");
        s.HasAliasCollision.Should().BeFalse();
    }

    [Fact]
    public void Alias_disabled_falls_back_to_legacy_wake_word()
    {
        var s = new SidecarSettings { WakeAliasEnabled = false, WakeWord = "hey-jarvis" };
        s.EffectiveWakeAlias.Should().Be("hey-jarvis");
    }

    [Fact]
    public void Empty_alias_falls_back_to_legacy_wake_word()
    {
        var s = new SidecarSettings { LocalWakeAlias = "", WakeWord = "hey-jarvis" };
        s.EffectiveWakeAlias.Should().Be("hey-jarvis");
    }

    [Fact]
    public void Collision_detected_when_alias_equals_identity()
    {
        var s = new SidecarSettings { LocalWakeAlias = "Jarvis", AssistantIdentityName = "Jarvis" };
        s.HasAliasCollision.Should().BeTrue();
    }

    [Fact]
    public void Collision_is_case_insensitive_and_trim_safe()
    {
        var s = new SidecarSettings { LocalWakeAlias = "  jarvis ", AssistantIdentityName = "Jarvis" };
        s.HasAliasCollision.Should().BeTrue();
    }

    [Fact]
    public void Disabled_alias_never_collides()
    {
        var s = new SidecarSettings { WakeAliasEnabled = false, LocalWakeAlias = "Jarvis", AssistantIdentityName = "Jarvis" };
        s.HasAliasCollision.Should().BeFalse();
    }
}
