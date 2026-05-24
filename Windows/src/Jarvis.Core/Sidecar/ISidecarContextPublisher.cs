namespace Jarvis.Core.Sidecar;

/// <summary>
/// Subscribes to PerceptionService.Changed and forwards a compact ContextPayload over
/// the bridge whenever the snapshot hash changes. Coalesces bursts (100 ms debounce) and
/// honours privacy mode by suppressing entirely. Never sends raw screenshots / full
/// clipboard payloads — only summaries already prepared by the budgeter.
/// </summary>
public interface ISidecarContextPublisher : IAsyncDisposable
{
    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);

    /// <summary>Number of unique context frames published since boot.</summary>
    int Published { get; }
    /// <summary>Number of redundant snapshots dropped because the hash matched the prior one.</summary>
    int Deduplicated { get; }
}
