using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using Jarvis.Perception.Capture;

namespace Jarvis.App.Capture;

/// <summary>
/// GDI-based screen grab. CopyFromScreen is fast enough for moderate regions and avoids
/// the DXGI Duplication API's per-monitor session complexity (which becomes worth it
/// only if we move to continuous capture — explicitly out of scope for P2).
/// </summary>
public sealed class GdiScreenGrabber : IScreenGrabber
{
    public byte[] CaptureToPng(RegionSelection selection)
    {
        var b = selection.Bounds;
        if (b.Width <= 0 || b.Height <= 0) return Array.Empty<byte>();

        using var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(b.Left, b.Top, 0, 0, new System.Drawing.Size(b.Width, b.Height), CopyPixelOperation.SourceCopy);
        }
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    }
}
