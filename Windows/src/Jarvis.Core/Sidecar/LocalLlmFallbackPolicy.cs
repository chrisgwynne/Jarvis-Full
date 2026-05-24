namespace Jarvis.Core.Sidecar;

/// <summary>
/// Single authoritative rule: Windows may only use its local LLM provider when the Mac
/// bridge is not connected AND the user has explicitly opted in to offline degraded mode.
///
/// Extracted as a testable policy so callers cannot invent their own interpretation and
/// so the invariant can be asserted in isolation from the DegradedModeRouter.
/// </summary>
public static class LocalLlmFallbackPolicy
{
    /// <summary>
    /// Returns true only when local LLM use is permitted.
    ///
    /// Returns false when:
    ///   - bridge is Connected (Mac brain is reachable — always prefer it)
    ///   - bridge is Connecting/Reconnecting (wait for Mac before using local)
    ///   - offline degraded mode is disabled by the user
    ///
    /// Windows is a sidecar. Local LLM is a last resort, never the default path.
    /// </summary>
    public static bool CanUseLocalLlm(BridgeState bridgeState, bool offlineDegradedEnabled)
        => bridgeState != BridgeState.Connected && offlineDegradedEnabled;
}
