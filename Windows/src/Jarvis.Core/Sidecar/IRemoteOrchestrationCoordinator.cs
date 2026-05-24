namespace Jarvis.Core.Sidecar;

/// <summary>
/// Windows-side handler for the orchestration frames Mac sends to coordinate which
/// device speaks / stays silent / shows a proactive notification. Mac is the authority;
/// this coordinator merely applies inbound decisions to local state.
///
/// Counters surface for diagnostics — every orchestration decision should be observable
/// after the fact ("why did Pebble stay silent at 14:02?").
/// </summary>
public interface IRemoteOrchestrationCoordinator : IDisposable
{
    int SilenceCommands { get; }
    int SpeakCommands { get; }
    int ProactiveNotifications { get; }

    /// <summary>Subscribes to the bridge's FrameReceived. Safe to call after reconnect.</summary>
    void Attach();

    /// <summary>Fired when Mac asks this device to speak (lease implied). The TTS path
    /// honours this — speech will not begin unless a lease arrives as a follow-up frame.</summary>
    event EventHandler<string>? SpeakRequested;

    /// <summary>Fired when Mac asks this device to stay silent (e.g. another device is
    /// taking the turn). The lease coordinator already enforces single-speaker, but the
    /// renderer uses this for a subtle visual cue.</summary>
    event EventHandler? SilenceRequested;

    /// <summary>Fired when Mac broadcasts a proactive notification (visual on this device;
    /// speech only if a lease has been granted).</summary>
    event EventHandler<ProactiveNotice>? ProactiveReceived;
}

public sealed record ProactiveNotice(
    string? Title,
    string? Body,
    string? Source,
    DateTimeOffset At);
