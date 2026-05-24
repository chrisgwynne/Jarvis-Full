using Jarvis.Core.Awareness;

namespace Jarvis.Core.Perception;

public sealed record RegionCaptureResult(
    DateTimeOffset CapturedAt,
    Rect Bounds,
    int MonitorIndex,
    byte[] PngBytes,
    int Width,
    int Height,
    double DpiScale);

public enum CaptureCancellationReason { UserCancelled, NoSelection, Error }

public sealed record RegionCaptureCancelled(CaptureCancellationReason Reason, string? Message);

public interface IRegionCapture
{
    /// <summary>
    /// Begin an interactive region selection. Resolves with a capture or null if cancelled.
    /// Implementations must be safe to call concurrently — only one capture flow is permitted at a time.
    /// </summary>
    Task<RegionCaptureResult?> CaptureAsync(CancellationToken cancellationToken = default);

    bool IsCapturing { get; }
    event EventHandler<RegionCaptureResult>? Captured;
    event EventHandler<RegionCaptureCancelled>? Cancelled;
}
