using Microsoft.Extensions.Logging;

namespace Jarvis.Core.State;

/// <summary>
/// Deterministic, single-threaded state resolver. The machine itself holds no timers
/// or I/O — callers push <see cref="PebbleStateInputs"/> snapshots and observe transitions.
///
/// Priority (highest first) so simultaneous signals collapse predictably:
///   Error &gt; Alert &gt; Muted &gt; Speaking &gt; Listening &gt; Thinking &gt; Working &gt; Focused &gt; Idle
/// </summary>
public sealed class PebbleStateMachine
{
    private readonly ILogger<PebbleStateMachine>? _logger;
    private readonly object _gate = new();
    private PebbleState _current = PebbleState.Idle;
    private PebbleStateInputs _lastInputs = PebbleStateInputs.Empty;
    private DateTimeOffset _enteredCurrentAt = DateTimeOffset.UtcNow;

    public event EventHandler<PebbleStateTransition>? Transitioned;

    public PebbleStateMachine(ILogger<PebbleStateMachine>? logger = null)
    {
        _logger = logger;
    }

    public PebbleState Current
    {
        get { lock (_gate) return _current; }
    }

    public PebbleStateInputs LastInputs
    {
        get { lock (_gate) return _lastInputs; }
    }

    /// <summary>Apply a new input snapshot. Returns the resolved state.</summary>
    public PebbleState Apply(PebbleStateInputs inputs)
    {
        PebbleStateTransition? transition = null;
        PebbleState next;
        lock (_gate)
        {
            next = Resolve(inputs);
            _lastInputs = inputs;
            if (next != _current)
            {
                var now = DateTimeOffset.UtcNow;
                var dwell = now - _enteredCurrentAt;
                transition = new PebbleStateTransition(_current, next, now, ReasonFor(inputs, next), dwell);
                _current = next;
                _enteredCurrentAt = now;
            }
        }

        if (transition is { } t)
        {
            _logger?.LogDebug("Pebble {From} -> {To} ({Reason})", t.From, t.To, t.Reason);
            Transitioned?.Invoke(this, t);
        }
        return next;
    }

    private static PebbleState Resolve(PebbleStateInputs i)
    {
        if (i.HasError) return PebbleState.Error;
        if (i.HasAlert) return PebbleState.Alert;
        if (i.Muted) return PebbleState.Muted;
        if (i.TtsSpeaking) return PebbleState.Speaking;
        if (i.RemoteSpeaking) return PebbleState.SpeakingRemote;
        if (i.Listening || i.MicrophoneOpen) return PebbleState.Listening;
        if (i.BridgeReconnecting) return PebbleState.Reconnecting;
        if (i.BridgeDegraded) return PebbleState.Degraded;
        if (i.AutomationRunning) return PebbleState.Working;
        if (i.Interrupted) return PebbleState.Thinking;
        if (!string.IsNullOrEmpty(i.ActiveTask)) return PebbleState.Working;
        if (i.UserActive && !string.IsNullOrEmpty(i.ForegroundApp)) return PebbleState.Focused;
        return PebbleState.Idle;
    }

    private static string ReasonFor(PebbleStateInputs i, PebbleState next) => next switch
    {
        PebbleState.Error => "HasError",
        PebbleState.Alert => "HasAlert",
        PebbleState.Muted => "Muted",
        PebbleState.Speaking => "TtsSpeaking",
        PebbleState.Listening => i.Listening ? "Listening" : "MicrophoneOpen",
        PebbleState.Working => i.AutomationRunning ? "Automation" : $"ActiveTask={i.ActiveTask}",
        PebbleState.Thinking => "Interrupted",
        PebbleState.Focused => $"Foreground={i.ForegroundApp}",
        PebbleState.Idle => "no signals",
        _ => "transition"
    };
}
