namespace Jarvis.Core.State;

/// <summary>
/// Snapshot of every signal the state machine consumes.
/// Immutable: produce a new instance per update via <c>with</c>.
/// </summary>
public readonly record struct PebbleStateInputs(
    bool MicrophoneOpen,
    bool Listening,
    bool TtsSpeaking,
    bool AutomationRunning,
    bool UserActive,
    bool Interrupted,
    bool Muted,
    bool HasError,
    bool HasAlert,
    string? ForegroundApp,
    string? ActiveTask,
    /// <summary>Mac is currently speaking. Set by the bridge's speaker.active frame.</summary>
    bool RemoteSpeaking = false,
    /// <summary>Bridge reconnecting after a drop.</summary>
    bool BridgeReconnecting = false,
    /// <summary>Bridge gave up reconnecting; local fallback in effect.</summary>
    bool BridgeDegraded = false,
    /// <summary>Wake word just detected — short-lived (~1 s) ripple signal.</summary>
    bool WakeDetected = false,
    /// <summary>User just interrupted TTS — short-lived (~600 ms) flash signal.</summary>
    bool InterruptedFlash = false)
{
    public static PebbleStateInputs Empty => new(
        MicrophoneOpen: false,
        Listening: false,
        TtsSpeaking: false,
        AutomationRunning: false,
        UserActive: true,
        Interrupted: false,
        Muted: false,
        HasError: false,
        HasAlert: false,
        ForegroundApp: null,
        ActiveTask: null,
        RemoteSpeaking: false,
        BridgeReconnecting: false,
        BridgeDegraded: false,
        WakeDetected: false,
        InterruptedFlash: false);
}
