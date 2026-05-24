using System.Collections.Concurrent;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Default implementation. Queue is a fixed-cap ConcurrentQueue with drop-oldest under
/// pressure — high-volume partial transcripts are deliberately allowed to be dropped
/// because finals (which the Mac actually needs to stitch) are smaller in count and
/// rarely overflow the cap.
/// </summary>
public sealed class DistributedFallbackCoordinator : IDistributedFallbackCoordinator
{
    private const int QueueCap = 128;

    private readonly IMacBridgeCoordinator _bridge;
    private readonly IDiagnostics? _diagnostics;
    private readonly ConcurrentQueue<SidecarFrame> _queue = new();
    private int _queued;
    private int _flushedTotal;
    private bool _buffering;
    private BridgeState _lastState = BridgeState.Disabled;

    public bool IsBuffering => _buffering;
    public int Queued => _queued;
    public int FlushedTotal => _flushedTotal;

    public DistributedFallbackCoordinator(IMacBridgeCoordinator bridge, IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _diagnostics = diagnostics;
        _bridge.StatusChanged += OnStatusChanged;
    }

    public bool ForwardOrQueue(SidecarFrame frame)
    {
        var status = _bridge.Status.State;
        if (status == BridgeState.Connected)
        {
            // Normal path — straight through.
            _ = _bridge.SendAsync(frame);
            return true;
        }
        // Degraded / Reconnecting / Disabled — queue with cap.
        if (_queue.Count >= QueueCap)
        {
            // Drop-oldest so the most recent frames survive (Mac cares more about "what
            // just happened" than "what happened five minutes ago").
            _queue.TryDequeue(out _);
            Interlocked.Decrement(ref _queued);
        }
        _queue.Enqueue(frame);
        Interlocked.Increment(ref _queued);
        _buffering = true;
        return true;
    }

    private void OnStatusChanged(object? sender, BridgeStatus status)
    {
        var was = _lastState;
        _lastState = status.State;

        if (status.State == BridgeState.Connected && _queue.Count > 0)
        {
            // Replay the offline window. Mac uses replay.begin / replay.end markers to
            // know these are catch-up frames, not live ones.
            _diagnostics?.Record(DiagnosticLevel.Info, "fallback", "replaying offline window",
                new Dictionary<string, object?> { ["count"] = _queue.Count, ["from"] = was.ToString() });

            _ = _bridge.SendAsync(new SidecarFrame
            {
                Type = SidecarFrameTypes.ReplayBegin,
                At = DateTimeOffset.UtcNow
            });

            int flushed = 0;
            while (_queue.TryDequeue(out var frame))
            {
                _ = _bridge.SendAsync(frame);
                Interlocked.Decrement(ref _queued);
                flushed++;
            }
            Interlocked.Add(ref _flushedTotal, flushed);

            _ = _bridge.SendAsync(new SidecarFrame
            {
                Type = SidecarFrameTypes.ReplayEnd,
                At = DateTimeOffset.UtcNow
            });
            _buffering = false;
        }
        else if (status.State != BridgeState.Connected)
        {
            _buffering = _queue.Count > 0;
        }
    }

    public void Dispose()
    {
        _bridge.StatusChanged -= OnStatusChanged;
    }
}
