namespace Jarvis.Core.Sidecar;

public enum SpeakerOwner
{
    /// <summary>No one is currently speaking.</summary>
    None,
    /// <summary>The Mac brain is speaking. Windows must stay silent.</summary>
    Mac,
    /// <summary>Windows has been granted a lease and may speak now.</summary>
    Windows
}

public sealed record LeaseState(
    SpeakerOwner Owner,
    string? Token,
    DateTimeOffset? ExpiresAtUtc,
    string? Reason);

public interface ITtsLeaseCoordinator
{
    LeaseState Current { get; }
    event EventHandler<LeaseState>? Changed;

    /// <summary>Called by Windows when local TTS would like to speak. Returns true if a
    /// lease is already held (or was granted synchronously); false if Mac authority
    /// hasn't approved. Mac is the authority — Windows never grants its own lease.</summary>
    bool RequestLocalLease(string reason);

    /// <summary>Apply an inbound bridge frame (lease.grant / lease.revoke / speaker.active /
    /// speaker.silent). Frames from other types are ignored.</summary>
    void ApplyInbound(SidecarFrame frame);

    /// <summary>Called by the local TTS service to declare that Windows is about to speak
    /// (must hold a Windows-owner lease) or has finished. Updates state and emits the
    /// matching <c>speaker.start</c>/<c>speaker.end</c> frame upstream.</summary>
    void NotifyLocalSpeaking(bool speaking);
}
