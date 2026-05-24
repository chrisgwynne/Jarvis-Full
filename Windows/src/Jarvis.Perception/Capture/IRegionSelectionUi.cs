using Jarvis.Core.Awareness;

namespace Jarvis.Perception.Capture;

public sealed record RegionSelection(Rect Bounds, int MonitorIndex, double DpiScale);

/// <summary>
/// Adapter to whatever UI shows the dimming overlay and reads the user's drag rectangle.
/// Implemented in Jarvis.App so the perception project stays headless-testable.
/// </summary>
public interface IRegionSelectionUi
{
    Task<RegionSelection?> SelectAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Captures a screen rectangle to PNG bytes. Implementations decide the backing API
/// (GDI BitBlt, DXGI, Graphics.CopyFromScreen). Jarvis.App ships the default GDI version.
/// </summary>
public interface IScreenGrabber
{
    byte[] CaptureToPng(RegionSelection selection);
}
