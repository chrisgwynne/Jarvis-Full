using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Single-speaker authority. Mac is authoritative — only the Mac may *grant* a Windows
/// lease. Windows can announce that it's about to speak (or just spoke) via
/// <see cref="NotifyLocalSpeaking"/>, which emits speaker.active / speaker.silent frames.
///
/// State transitions (only valid edges):
///   None        --lease.grant->   Windows
///   None        --speaker.active--mac->  Mac
///   Mac         --speaker.silent--mac--> None
///   Windows     --lease.revoke->  None
///   Windows     --local stop->    None
/// </summary>
public sealed class TtsLeaseCoordinator : ITtsLeaseCoordinator
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();
    private LeaseState _state = new(SpeakerOwner.None, null, null, null);

    public TtsLeaseCoordinator(IMacBridgeCoordinator bridge, IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _diagnostics = diagnostics;
    }

    public LeaseState Current { get { lock (_gate) return _state; } }
    public event EventHandler<LeaseState>? Changed;

    public bool RequestLocalLease(string reason)
    {
        lock (_gate)
        {
            if (_state.Owner == SpeakerOwner.Windows) return true;
        }
        // Ask the Mac for a lease; never grant ourselves.
        _ = _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.LeaseRequest,
            Reason = reason,
            At = DateTimeOffset.UtcNow
        });
        return false;
    }

    public void ApplyInbound(SidecarFrame frame)
    {
        if (frame is null) return;
        LeaseState? next = frame.Type switch
        {
            SidecarFrameTypes.LeaseGrant => new LeaseState(SpeakerOwner.Windows, frame.LeaseToken,
                frame.LeaseExpiresAt, frame.Reason),
            SidecarFrameTypes.LeaseRevoke => new LeaseState(SpeakerOwner.None, null, null, "revoked"),
            SidecarFrameTypes.SpeakerActive when frame.Source == "mac" => new LeaseState(SpeakerOwner.Mac, null, null, "mac speaking"),
            SidecarFrameTypes.SpeakerSilent when frame.Source == "mac" => Current.Owner == SpeakerOwner.Mac
                ? new LeaseState(SpeakerOwner.None, null, null, null) : null,
            _ => null
        };
        if (next is null) return;
        Update(next);
    }

    public void NotifyLocalSpeaking(bool speaking)
    {
        lock (_gate)
        {
            if (speaking && _state.Owner != SpeakerOwner.Windows)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "sidecar.lease", "local speak attempted without lease");
                return;
            }
        }
        _ = _bridge.SendAsync(new SidecarFrame
        {
            Type = speaking ? SidecarFrameTypes.SpeakerActive : SidecarFrameTypes.SpeakerSilent,
            Source = "windows",
            At = DateTimeOffset.UtcNow
        });
        if (!speaking) Update(new LeaseState(SpeakerOwner.None, null, null, "local finished"));
    }

    /// <summary>Test seam: set the lease state directly. Production code uses the bridge.</summary>
    internal void TestOnlySet(LeaseState state) => Update(state);

    private void Update(LeaseState next)
    {
        LeaseState before;
        lock (_gate) { before = _state; _state = next; }
        if (before != next)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "sidecar.lease", $"{before.Owner} → {next.Owner}",
                new Dictionary<string, object?> { ["reason"] = next.Reason });
            Changed?.Invoke(this, next);
        }
    }
}
