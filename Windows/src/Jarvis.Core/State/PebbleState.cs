namespace Jarvis.Core.State;

/// <summary>
/// Visual / behavioural states the Pebble can occupy.
/// Order is stable — the WebView renderer reads the enum name as a CSS class.
/// </summary>
public enum PebbleState
{
    Idle,
    Listening,
    Thinking,
    Speaking,
    Working,
    Alert,
    Focused,
    Muted,
    Error,
    /// <summary>Mac brain is speaking — Windows is silent but the pebble pulses softly.</summary>
    SpeakingRemote,
    /// <summary>Bridge lost; reconnect in progress.</summary>
    Reconnecting,
    /// <summary>Bridge down for long enough that we're running local-only fallback.</summary>
    Degraded
}
