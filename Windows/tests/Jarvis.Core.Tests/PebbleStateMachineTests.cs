using FluentAssertions;
using Jarvis.Core.State;
using Xunit;

namespace Jarvis.Core.Tests;

public class PebbleStateMachineTests
{
    [Fact]
    public void Defaults_to_idle()
    {
        var sm = new PebbleStateMachine();
        sm.Current.Should().Be(PebbleState.Idle);
    }

    [Fact]
    public void Error_outranks_every_other_signal()
    {
        var sm = new PebbleStateMachine();
        var inputs = PebbleStateInputs.Empty with
        {
            HasError = true,
            HasAlert = true,
            Muted = true,
            TtsSpeaking = true,
            Listening = true,
            AutomationRunning = true
        };
        sm.Apply(inputs).Should().Be(PebbleState.Error);
    }

    [Fact]
    public void Alert_beats_muted_speaking_listening()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { HasAlert = true, Muted = true, TtsSpeaking = true })
            .Should().Be(PebbleState.Alert);
    }

    [Fact]
    public void Muted_beats_speaking()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { Muted = true, TtsSpeaking = true })
            .Should().Be(PebbleState.Muted);
    }

    [Fact]
    public void Speaking_beats_listening()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { TtsSpeaking = true, Listening = true })
            .Should().Be(PebbleState.Speaking);
    }

    [Fact]
    public void Listening_when_mic_open_even_without_explicit_listening_flag()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { MicrophoneOpen = true })
            .Should().Be(PebbleState.Listening);
    }

    [Fact]
    public void Automation_running_yields_working()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { AutomationRunning = true })
            .Should().Be(PebbleState.Working);
    }

    [Fact]
    public void Interrupted_without_other_signals_yields_thinking()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { Interrupted = true })
            .Should().Be(PebbleState.Thinking);
    }

    [Fact]
    public void Foreground_app_with_active_user_yields_focused()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { ForegroundApp = "devenv", UserActive = true })
            .Should().Be(PebbleState.Focused);
    }

    [Fact]
    public void Idle_user_with_no_signals_yields_idle()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { UserActive = false })
            .Should().Be(PebbleState.Idle);
    }

    [Fact]
    public void Transition_event_fires_with_correct_from_and_to()
    {
        var sm = new PebbleStateMachine();
        PebbleStateTransition? captured = null;
        sm.Transitioned += (_, t) => captured = t;

        sm.Apply(PebbleStateInputs.Empty with { Listening = true });

        captured.Should().NotBeNull();
        captured!.Value.From.Should().Be(PebbleState.Idle);
        captured.Value.To.Should().Be(PebbleState.Listening);
    }

    [Fact]
    public void No_event_when_state_unchanged()
    {
        var sm = new PebbleStateMachine();
        sm.Apply(PebbleStateInputs.Empty with { Listening = true });
        var count = 0;
        sm.Transitioned += (_, _) => count++;
        sm.Apply(PebbleStateInputs.Empty with { Listening = true, MicrophoneOpen = true });
        count.Should().Be(0);
    }

    [Fact]
    public async Task Apply_is_thread_safe_under_contention()
    {
        var sm = new PebbleStateMachine();
        var tasks = Enumerable.Range(0, 32).Select(i => Task.Run(() =>
        {
            for (var j = 0; j < 200; j++)
            {
                sm.Apply(PebbleStateInputs.Empty with { Listening = (i + j) % 2 == 0 });
            }
        })).ToArray();
        await Task.WhenAll(tasks);
        sm.Current.Should().BeOneOf(PebbleState.Idle, PebbleState.Listening);
    }
}
