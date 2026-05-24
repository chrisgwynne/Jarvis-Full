namespace Jarvis.Core.Input;

public enum MouseButton { Left, Right }

public enum ChordIgnoreReason
{
    None,
    /// <summary>Second button arrived too late after the first — not a chord.</summary>
    OutsideThreshold,
    /// <summary>Both buttons already down; chord already fired this gesture.</summary>
    AlreadyArmed,
    /// <summary>Chord disabled via settings.</summary>
    Disabled
}

/// <summary>
/// Pure-logic mouse-chord detector. Tracks left and right button up/down events with
/// timestamps and fires <see cref="ChordDetected"/> exactly once per gesture — when both
/// buttons reach down-state within <see cref="ThresholdMs"/> of each other.
///
/// Critically, this class does NOT consume mouse events. The hook layer above it
/// keeps calling <c>CallNextHookEx</c> for every event so normal left- and right-clicks
/// behave normally. The chord is purely additive.
///
/// Reset semantics:
///   - Once both buttons are down and the chord has fired, further down/up events from
///     either button are ignored until BOTH buttons have been released.
///   - This means holding both buttons (e.g. drag with chord modifier) doesn't spam the
///     menu open.
///   - Releasing one button while the other stays down doesn't re-arm — the user must
///     release both to gesture again.
/// </summary>
public sealed class MouseChordDetector
{
    private readonly object _gate = new();
    private bool _leftDown, _rightDown;
    private DateTimeOffset _leftDownAt = DateTimeOffset.MinValue;
    private DateTimeOffset _rightDownAt = DateTimeOffset.MinValue;
    private bool _armed; // chord has already fired this gesture
    private DateTimeOffset _lastChordAt = DateTimeOffset.MinValue;

    public int ThresholdMs { get; set; } = 250;
    public bool Enabled { get; set; } = true;

    /// <summary>Fired exactly once per chord gesture. Args carry the time delta between
    /// the two button-down events so diagnostics can see how tight the chord was.</summary>
    public event EventHandler<ChordEvent>? ChordDetected;

    /// <summary>Fired when an event was suppressed for one of the documented reasons.
    /// Used purely for diagnostics — no behaviour depends on it.</summary>
    public event EventHandler<ChordIgnoreReason>? ChordIgnored;

    public bool BothDown { get { lock (_gate) return _leftDown && _rightDown; } }
    public DateTimeOffset LastChordAt { get { lock (_gate) return _lastChordAt; } }

    /// <summary>Feed a mouse-down event. Returns true iff the chord just fired.</summary>
    public bool OnButtonDown(MouseButton button, DateTimeOffset at)
    {
        ChordEvent? fire = null;
        ChordIgnoreReason ignored = ChordIgnoreReason.None;
        lock (_gate)
        {
            if (!Enabled)
            {
                ignored = ChordIgnoreReason.Disabled;
            }
            else if (_armed)
            {
                // Chord already consumed this gesture — ignore repeats while either stays down.
                ignored = ChordIgnoreReason.AlreadyArmed;
            }
            else
            {
                if (button == MouseButton.Left)  { _leftDown  = true; _leftDownAt  = at; }
                else                             { _rightDown = true; _rightDownAt = at; }

                if (_leftDown && _rightDown)
                {
                    var delta = (_leftDownAt > _rightDownAt ? _leftDownAt - _rightDownAt
                                                            : _rightDownAt - _leftDownAt);
                    if (delta.TotalMilliseconds <= ThresholdMs)
                    {
                        _armed = true;
                        _lastChordAt = at;
                        fire = new ChordEvent(at, delta);
                    }
                    else
                    {
                        ignored = ChordIgnoreReason.OutsideThreshold;
                    }
                }
            }
        }
        if (fire is { } ev) ChordDetected?.Invoke(this, ev);
        if (ignored != ChordIgnoreReason.None) ChordIgnored?.Invoke(this, ignored);
        return fire is not null;
    }

    /// <summary>Feed a mouse-up event. Resets the armed flag once both buttons are up.</summary>
    public void OnButtonUp(MouseButton button)
    {
        lock (_gate)
        {
            if (button == MouseButton.Left)  _leftDown  = false;
            else                             _rightDown = false;
            if (!_leftDown && !_rightDown) _armed = false;
        }
    }

    /// <summary>Test seam: clear all state.</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _leftDown = _rightDown = _armed = false;
            _leftDownAt = _rightDownAt = DateTimeOffset.MinValue;
        }
    }
}

public readonly record struct ChordEvent(DateTimeOffset At, TimeSpan Delta);
