using FluentAssertions;
using Jarvis.Core.State;
using Xunit;

namespace Jarvis.Core.Tests;

public class PebbleStateDwellTests
{
    [Fact]
    public void First_transition_after_idle_carries_a_dwell_time()
    {
        var m = new PebbleStateMachine();
        PebbleStateTransition? captured = null;
        m.Transitioned += (_, t) => captured = t;

        // Stay in Idle a moment, then transition out.
        Thread.Sleep(40);
        m.Apply(PebbleStateInputs.Empty with { TtsSpeaking = true });

        captured.Should().NotBeNull();
        captured!.Value.From.Should().Be(PebbleState.Idle);
        captured.Value.To.Should().Be(PebbleState.Speaking);
        captured.Value.DwellTime.Should().BeGreaterThan(TimeSpan.Zero);
    }

    [Fact]
    public void Same_state_no_transition_no_event()
    {
        var m = new PebbleStateMachine();
        var fires = 0;
        m.Transitioned += (_, _) => fires++;
        m.Apply(PebbleStateInputs.Empty);
        m.Apply(PebbleStateInputs.Empty);
        fires.Should().Be(0);
    }
}
