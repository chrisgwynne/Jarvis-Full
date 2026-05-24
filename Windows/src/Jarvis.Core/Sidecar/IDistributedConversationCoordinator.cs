namespace Jarvis.Core.Sidecar;

/// <summary>
/// Owns the *one* distributed conversation session id this Windows sidecar contributes
/// to. The Mac brain is authoritative — Windows never forks the session — but Windows
/// must hold onto a stable id across restarts so the Mac can stitch transcripts to the
/// same rolling conversation even when the bridge bounced.
///
/// Architectural invariant: there is exactly one Jarvis identity, one memory, one
/// conversation. This coordinator does NOT store conversation content; it only tags
/// outbound transcripts with the right session/device/alias attribution.
/// </summary>
public interface IDistributedConversationCoordinator
{
    /// <summary>Persistent session id used to tag every outbound transcript. Stable
    /// across reconnects + restarts; rotated only when the user explicitly clears
    /// conversation history.</summary>
    string SessionId { get; }

    /// <summary>Stable device identifier for this Windows host. Used for attribution +
    /// orchestration ("did the request come from the desk machine or the laptop?").</summary>
    string DeviceId { get; }

    /// <summary>The local wake alias resolved from settings (e.g. "Pebble"). Mac brain
    /// treats all aliases as the same identity; this is metadata only.</summary>
    string WakeAlias { get; }

    /// <summary>Fired when Mac asks the device to clear its local cache (start a new
    /// distributed session). Implementations rotate <see cref="SessionId"/>.</summary>
    event EventHandler? SessionRotated;

    /// <summary>Rotate the session id — used when the user explicitly clears history or
    /// Mac sends a session.reset frame.</summary>
    void RotateSession(string reason);
}
