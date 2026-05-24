namespace Jarvis.Core.Sidecar;

public enum BridgeState
{
    /// <summary>Disabled in settings; not attempting.</summary>
    Disabled,
    /// <summary>Bringing the connection up.</summary>
    Connecting,
    /// <summary>Connected + handshake completed.</summary>
    Connected,
    /// <summary>Lost the connection; backoff timer running.</summary>
    Reconnecting,
    /// <summary>Bridge unreachable for long enough that the degraded-mode threshold tripped.</summary>
    Degraded,
    /// <summary>Gateway mode: no valid session token — must pair via /v1/windows/pair first.</summary>
    PairingRequired,
    /// <summary>Gateway mode: authentication rejected (401); will not retry until reconfigured.</summary>
    Unauthorized,
    /// <summary>Gateway mode: daemon explicitly revoked the session token; must re-pair.</summary>
    TokenRevoked
}

public sealed record BridgeStatus(
    BridgeState State,
    DateTimeOffset SinceUtc,
    int ReconnectAttempts,
    double? LastRoundTripMs,
    string? LastError,
    DateTimeOffset? LastSuccessfulConnectAt = null,
    DateTimeOffset? DegradedModeEnteredAt = null);

/// <summary>
/// Owns the Mac-bound WebSocket. All inbound frames are surfaced via
/// <see cref="FrameReceived"/>; outbound frames go through <see cref="SendAsync"/>.
/// Reconnect + heartbeat + degraded-mode transitions are internal.
/// </summary>
public interface IMacBridgeCoordinator : IAsyncDisposable
{
    BridgeStatus Status { get; }
    event EventHandler<BridgeStatus>? StatusChanged;
    event EventHandler<SidecarFrame>? FrameReceived;

    /// <summary>Start the bridge (idempotent). Settings drive whether it actually connects.</summary>
    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);

    /// <summary>Fire-and-forget send. Returns false (no throw) when the socket isn't ready.
    /// Outbound queue protects against overflow by dropping the oldest frame.</summary>
    Task<bool> SendAsync(SidecarFrame frame, CancellationToken cancellationToken = default);
}
