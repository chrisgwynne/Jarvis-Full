namespace Jarvis.Core.Sidecar;

/// <summary>
/// Receives <c>execute.intent</c> frames from the Mac, parses the intent, and runs it
/// through <see cref="Jarvis.Core.Automation.IAutomationExecutor"/> — which means the
/// existing approval policy, rate limiter, audit log and elevation guard ALL apply.
/// The Mac cannot bypass any of them. Sends an <c>execute.ack</c> back with the outcome.
/// </summary>
public interface IRemoteExecutionBridge : IDisposable
{
    int Accepted { get; }
    int Rejected { get; }
    int Failed { get; }

    /// <summary>Subscribes to <see cref="IMacBridgeCoordinator.FrameReceived"/>.
    /// Idempotent; safe to call after a reconnect.</summary>
    void Attach();
}
