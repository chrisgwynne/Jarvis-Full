namespace Jarvis.Core.Presence;

/// <summary>
/// Discrete attention modes the Pebble responds to. The model resolves these
/// deterministically from observed signals — never from heuristics about *intent*.
/// </summary>
public enum AttentionMode
{
    /// <summary>User is at the keyboard producing characters quickly. Pebble dampens
    /// breathing + halo opacity so it doesn't compete with active work.</summary>
    Focused,
    /// <summary>Slow cursor + no typing + foreground stable. Pebble breathes normally.</summary>
    Ambient,
    /// <summary>Fast cursor / rapid app switching / recent interruption. Pebble snaps tight
    /// to the cursor and brightens slightly so it stays findable during chaos.</summary>
    Active,
    /// <summary>User idle past the threshold. Pebble drifts softer + dimmer.</summary>
    Idle
}

/// <summary>
/// Observed signals fed into <see cref="AmbientAttentionModel"/>. Updated incrementally;
/// the model holds short rolling state and doesn't allocate per tick.
/// </summary>
public readonly record struct AttentionSignals(
    /// <summary>Pixels-per-second magnitude of cursor velocity (instantaneous estimate).</summary>
    double CursorVelocity,
    /// <summary>Recent typing rate, characters per second over the last 2 s.</summary>
    double TypingRate,
    /// <summary>Number of foreground-app changes in the last 30 s.</summary>
    int RecentAppSwitches,
    /// <summary>Number of TTS interruptions in the last 30 s.</summary>
    int RecentInterruptions,
    /// <summary>Seconds since the last user input (mouse or keyboard).</summary>
    double IdleSeconds,
    /// <summary>True when the user has been on one app for >30 s with no switching.</summary>
    bool StableFocus);

/// <summary>
/// Maps observed user behaviour to an <see cref="AttentionMode"/> + a presence intensity
/// 0..1 used by the renderer to dial breathing / halo / motion. Pure logic — fully
/// testable. The class doesn't subscribe to any input sources itself; whoever owns the
/// cursor / typing / focus signals calls <see cref="Observe"/> at whatever cadence makes
/// sense (typically 4 Hz from the awareness service).
///
/// Design choices:
///   - Hysteresis: once Active is entered, stays Active for at least 1.5 s. Prevents
///     mode-flicker when cursor briefly slows mid-gesture.
///   - Idle wins over everything: 45 s+ of no input dominates regardless of velocity
///     (a stationary mouse over a stale game still reads as idle).
///   - Intensity is independent of mode — a Focused user typing furiously still has high
///     intensity; an Ambient user with no movement has low.
/// </summary>
public sealed class AmbientAttentionModel
{
    private static readonly TimeSpan ActiveHysteresis = TimeSpan.FromMilliseconds(1500);
    private const double FastCursorPxPerSec = 1200.0;
    private const double FocusedTypingThreshold = 3.0;  // ~normal touch-typing
    private const double IdleSecondsThreshold = 45.0;

    private readonly object _gate = new();
    private AttentionMode _mode = AttentionMode.Ambient;
    private DateTimeOffset _enteredActiveAt = DateTimeOffset.MinValue;
    private double _intensity = 0.4;

    public AttentionMode Mode { get { lock (_gate) return _mode; } }
    /// <summary>0..1 presence intensity. 0 = barely visible, 1 = fully energetic.</summary>
    public double Intensity { get { lock (_gate) return _intensity; } }

    public event EventHandler<AttentionMode>? ModeChanged;

    /// <summary>Feed a new signals snapshot. Returns the resolved mode after applying
    /// hysteresis.</summary>
    public AttentionMode Observe(AttentionSignals signals, DateTimeOffset? now = null)
    {
        var nowUtc = now ?? DateTimeOffset.UtcNow;
        AttentionMode resolved;
        AttentionMode previous;
        bool changed;
        lock (_gate)
        {
            previous = _mode;
            resolved = Resolve(signals, nowUtc, previous);
            _intensity = ComputeIntensity(signals, resolved);
            if (resolved == AttentionMode.Active && previous != AttentionMode.Active)
                _enteredActiveAt = nowUtc;
            changed = resolved != _mode;
            _mode = resolved;
        }
        if (changed) ModeChanged?.Invoke(this, resolved);
        return resolved;
    }

    private AttentionMode Resolve(AttentionSignals s, DateTimeOffset now, AttentionMode previous)
    {
        // Idle dominates everything.
        if (s.IdleSeconds >= IdleSecondsThreshold) return AttentionMode.Idle;

        // Active hysteresis: once entered, stay Active until at least 1.5 s have passed,
        // even if signals briefly drop. Prevents mode-thrash during a single drag gesture.
        if (previous == AttentionMode.Active && now - _enteredActiveAt < ActiveHysteresis)
            return AttentionMode.Active;

        var isActive = s.CursorVelocity > FastCursorPxPerSec
                    || s.RecentAppSwitches >= 3
                    || s.RecentInterruptions >= 1;
        if (isActive) return AttentionMode.Active;

        if (s.TypingRate > FocusedTypingThreshold || s.StableFocus)
            return AttentionMode.Focused;

        return AttentionMode.Ambient;
    }

    private static double ComputeIntensity(AttentionSignals s, AttentionMode mode)
    {
        // Idle drops to a calm floor. Active pegs near 1. Focused / Ambient blend the
        // continuous signals so the renderer can dial subtly without state-flip.
        if (mode == AttentionMode.Idle) return 0.15;
        if (mode == AttentionMode.Active) return 0.95;

        var typing = Math.Min(1.0, s.TypingRate / 6.0);
        var velocity = Math.Min(1.0, s.CursorVelocity / FastCursorPxPerSec);
        var blended = mode == AttentionMode.Focused
            ? 0.35 + 0.30 * typing       // focused floor=0.35, headroom for typing
            : 0.40 + 0.35 * velocity;    // ambient blend with motion
        return Math.Clamp(blended, 0.15, 0.95);
    }
}
