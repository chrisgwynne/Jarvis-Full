namespace Jarvis.Core.Sidecar;

/// <summary>
/// When the Mac bridge is in Degraded/Reconnecting state, the user must not feel a
/// dead app. This coordinator:
///   - subtly flips the renderer into the "disconnected brain" visual on transition,
///   - holds a bounded queue of high-value frames (transcripts + final context) so the
///     Mac brain can stitch the offline window back into the rolling conversation when
///     the bridge returns,
///   - sends a replay.begin / replay.end pair around the catch-up so Mac knows to merge
///     rather than treat as fresh, and
///   - never pretends to be connected. Degraded UX is honest.
///
/// This is NOT a backup brain. Local fallback chat continues to use DegradedModeRouter
/// → local LLM provider. The queued frames here are purely so Mac sees what happened.
/// </summary>
public interface IDistributedFallbackCoordinator : IDisposable
{
    /// <summary>True while the coordinator is actively queueing frames because the bridge
    /// is not Connected. Mostly used by the renderer + diagnostics.</summary>
    bool IsBuffering { get; }

    /// <summary>Count of frames queued during the current degraded window.</summary>
    int Queued { get; }

    /// <summary>Total frames flushed across all reconnects.</summary>
    int FlushedTotal { get; }

    /// <summary>Forward a frame through normal send if the bridge is up, otherwise queue
    /// it for later replay. Returns true if accepted (queued or sent).</summary>
    bool ForwardOrQueue(SidecarFrame frame);
}
