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
            // Two-lane drop: shed the oldest *evictable* frame (partials/heartbeats) but
            // never a transcript.final — the Mac needs every final to stitch the
            // conversation. Falls back to dropping the oldest only if the queue is all
            // finals (pathological), so the queue stays bounded.
            EvictOneNonFinal();
        }
        _queue.Enqueue(frame);
        Interlocked.Increment(ref _queued);
        _buffering = true;
        return true;
    }

    /// <summary>Dequeues one frame, preferring a non-final to drop. transcript.final frames
    /// scanned while searching are re-enqueued so they survive; if the queue is entirely
    /// finals the oldest is dropped as a last resort to keep the queue bounded.</summary>
    private void EvictOneNonFinal()
    {
        List<SidecarFrame>? preservedFinals = null;
        while (_queue.TryDequeue(out var head))
        {
            Interlocked.Decrement(ref _queued);
            if (!string.Equals(head.Type, SidecarFrameTypes.TranscriptFinal, StringComparison.Ordinal))
            {
                // Dropped a non-final. Restore the finals we set aside (re-counting them).
                if (preservedFinals is not null)
                    foreach (var f in preservedFinals) { _queue.Enqueue(f); Interlocked.Increment(ref _queued); }
                return;
            }
            (preservedFinals ??= new List<SidecarFrame>()).Add(head);
        }

        // Queue was all finals (or empty): re-enqueue all but the oldest.
        if (preservedFinals is { Count: > 0 })
        {
            for (var i = 1; i < preservedFinals.Count; i++)
            {
                _queue.Enqueue(preservedFinals[i]);
                Interlocked.Increment(ref _queued);
            }
            // index 0 (oldest final) intentionally dropped as last resort
        }
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
