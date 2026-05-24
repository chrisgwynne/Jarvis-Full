using FluentAssertions;
using Jarvis.Core.Presence;
using Xunit;

namespace Jarvis.Core.Tests;

public class AmbientAttentionModelTests
{
    [Fact]
    public void Defaults_to_Ambient_mode()
    {
        var m = new AmbientAttentionModel();
        m.Mode.Should().Be(AttentionMode.Ambient);
    }

    [Fact]
    public void Idle_dominates_over_velocity()
    {
        var m = new AmbientAttentionModel();
        // High velocity but past idle threshold — Idle still wins.
        var mode = m.Observe(new AttentionSignals(
            CursorVelocity: 5000, TypingRate: 0, RecentAppSwitches: 0,
            RecentInterruptions: 0, IdleSeconds: 60, StableFocus: false));
        mode.Should().Be(AttentionMode.Idle);
        m.Intensity.Should().BeLessThanOrEqualTo(0.2);
    }

    [Fact]
    public void Fast_cursor_or_app_switching_triggers_Active()
    {
        var m = new AmbientAttentionModel();
        m.Observe(new AttentionSignals(2000, 0, 0, 0, 0, false)).Should().Be(AttentionMode.Active);
        var m2 = new AmbientAttentionModel();
        m2.Observe(new AttentionSignals(0, 0, RecentAppSwitches: 4, 0, 0, false)).Should().Be(AttentionMode.Active);
    }

    [Fact]
    public void Active_has_hysteresis_dont_drop_immediately()
    {
        var m = new AmbientAttentionModel();
        var t = DateTimeOffset.UtcNow;
        m.Observe(new AttentionSignals(2500, 0, 0, 0, 0, false), t).Should().Be(AttentionMode.Active);
        // Cursor stops moving 200ms later — must still report Active (hysteresis 1.5 s).
        m.Observe(new AttentionSignals(0, 0, 0, 0, 0, false), t.AddMilliseconds(200))
            .Should().Be(AttentionMode.Active);
        // 2 s later, hysteresis has lapsed.
        m.Observe(new AttentionSignals(0, 0, 0, 0, 0, false), t.AddSeconds(2))
            .Should().Be(AttentionMode.Ambient);
    }

    [Fact]
    public void Stable_focus_or_typing_promotes_to_Focused()
    {
        var m = new AmbientAttentionModel();
        m.Observe(new AttentionSignals(0, TypingRate: 5, 0, 0, 0, false)).Should().Be(AttentionMode.Focused);
        var m2 = new AmbientAttentionModel();
        m2.Observe(new AttentionSignals(0, 0, 0, 0, 0, StableFocus: true)).Should().Be(AttentionMode.Focused);
    }

    [Fact]
    public void Interruption_counts_as_Active()
    {
        var m = new AmbientAttentionModel();
        m.Observe(new AttentionSignals(0, 0, 0, RecentInterruptions: 2, 0, false))
            .Should().Be(AttentionMode.Active);
    }

    [Fact]
    public void Mode_changed_fires_only_on_actual_transitions()
    {
        var m = new AmbientAttentionModel();
        var fires = 0;
        m.ModeChanged += (_, _) => fires++;
        m.Observe(new AttentionSignals(0, 0, 0, 0, 0, false)); // stays Ambient
        fires.Should().Be(0);
        m.Observe(new AttentionSignals(0, 6, 0, 0, 0, false)); // → Focused
        fires.Should().Be(1);
        m.Observe(new AttentionSignals(0, 6, 0, 0, 0, false)); // still Focused
        fires.Should().Be(1);
    }

    [Fact]
    public void Intensity_floor_idle_ceiling_active()
    {
        var m = new AmbientAttentionModel();
        m.Observe(new AttentionSignals(0, 0, 0, 0, 90, false));
        m.Intensity.Should().BeApproximately(0.15, 0.01);

        var m2 = new AmbientAttentionModel();
        m2.Observe(new AttentionSignals(3000, 0, 0, 0, 0, false));
        m2.Intensity.Should().BeApproximately(0.95, 0.01);
    }
}
