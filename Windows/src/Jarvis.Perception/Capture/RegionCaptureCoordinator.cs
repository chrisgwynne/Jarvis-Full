using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Capture;

/// <summary>
/// Region-capture state machine. Single-flight: a second concurrent CaptureAsync call
/// returns null immediately rather than queueing — the user pressing the hotkey twice
/// shouldn't stack overlays.
/// </summary>
public sealed class RegionCaptureCoordinator : IRegionCapture
{
    private readonly IRegionSelectionUi _ui;
    private readonly IScreenGrabber _grabber;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<RegionCaptureCoordinator>? _logger;
    private int _inFlight;

    public RegionCaptureCoordinator(
        IRegionSelectionUi ui,
        IScreenGrabber grabber,
        IDiagnostics? diagnostics = null,
        ILogger<RegionCaptureCoordinator>? logger = null)
    {
        _ui = ui;
        _grabber = grabber;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public bool IsCapturing => Volatile.Read(ref _inFlight) != 0;

    public event EventHandler<RegionCaptureResult>? Captured;
    public event EventHandler<RegionCaptureCancelled>? Cancelled;

    public async Task<RegionCaptureResult?> CaptureAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.CompareExchange(ref _inFlight, 1, 0) != 0)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "capture", "second invocation ignored");
            return null;
        }
        try
        {
            var selection = await _ui.SelectAsync(cancellationToken).ConfigureAwait(false);
            if (selection is null || selection.Bounds.IsEmpty)
            {
                Cancelled?.Invoke(this, new RegionCaptureCancelled(CaptureCancellationReason.UserCancelled, null));
                return null;
            }

            byte[] png;
            try
            {
                png = _grabber.CaptureToPng(selection);
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(ex, "Screen grab failed");
                _diagnostics?.Record(DiagnosticLevel.Warn, "capture", "screen grab failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
                Cancelled?.Invoke(this, new RegionCaptureCancelled(CaptureCancellationReason.Error, ex.Message));
                return null;
            }

            var result = new RegionCaptureResult(
                CapturedAt: DateTimeOffset.UtcNow,
                Bounds: selection.Bounds,
                MonitorIndex: selection.MonitorIndex,
                PngBytes: png,
                Width: selection.Bounds.Width,
                Height: selection.Bounds.Height,
                DpiScale: selection.DpiScale);

            _diagnostics?.Record(DiagnosticLevel.Debug, "capture", "captured",
                new Dictionary<string, object?>
                {
                    ["w"] = result.Width,
                    ["h"] = result.Height,
                    ["bytes"] = png.Length
                });
            Captured?.Invoke(this, result);
            return result;
        }
        finally
        {
            Volatile.Write(ref _inFlight, 0);
        }
    }
}
