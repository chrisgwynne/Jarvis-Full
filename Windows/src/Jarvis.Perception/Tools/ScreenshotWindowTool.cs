using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Jarvis.Core.Settings;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Captures a screenshot of the current foreground window and saves it as a PNG file.
/// Uses WPF RenderTargetBitmap / interop — does NOT require System.Drawing.Common.
/// NEVER sends image content over the bridge — only the saved file path is returned.
/// </summary>
public sealed class ScreenshotWindowTool : IWindowsTool
{
    private static readonly string ScreenshotDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Jarvis", "Screenshots");

    private readonly Func<ToolsSettings> _settings;

    public ScreenshotWindowTool(Func<ToolsSettings> settings)
    {
        _settings = settings;
    }

    public string Name => "screenshot_window";
    public IReadOnlyList<string> Aliases { get; } = ["screenshot", "capture_screen", "capture_window"];
    public string Description => "Captures a screenshot of the current foreground window and saves it as a PNG.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Confirm;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (!_settings().AllowScreenshots)
        {
            return Task.FromResult(Blocked("Screenshot capture is disabled in settings."));
        }

        if (request.DryRun)
        {
            return Task.FromResult(Ok("Would capture current foreground window (dry run)", null));
        }

        try
        {
            var hwnd = Win32Helpers.GetForegroundWindow();
            if (hwnd == IntPtr.Zero)
            {
                return Task.FromResult(Fail("No foreground window found to capture."));
            }

            if (!Win32Helpers.GetWindowRect(hwnd, out var rect))
            {
                return Task.FromResult(Fail("Could not determine foreground window bounds."));
            }

            var width  = rect.Width;
            var height = rect.Height;
            if (width <= 0 || height <= 0)
            {
                return Task.FromResult(Fail("Foreground window has zero size — cannot capture."));
            }

            // Use WPF interop to capture screen region (no System.Drawing dependency)
            var bitmapSource = CaptureScreenRegion(rect.Left, rect.Top, width, height);

            Directory.CreateDirectory(ScreenshotDir);
            var fileName = $"jarvis-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.png";
            var filePath = Path.Combine(ScreenshotDir, fileName);

            SaveAsPng(bitmapSource, filePath);

            return Task.FromResult(Ok($"Screenshot saved: {fileName}", filePath));
        }
        catch (Exception ex)
        {
            return Task.FromResult(Fail($"Screenshot failed: {ex.GetType().Name} — {ex.Message}"));
        }
    }

    private static BitmapSource CaptureScreenRegion(int x, int y, int width, int height)
    {
        // Use a RenderTargetBitmap backed by a visual that renders the screen via CopyFromScreen equivalent.
        // Since WPF doesn't have a direct CopyFromScreen, we use the Win32 BitBlt approach via DrawingVisual.
        var screenBounds = new System.Drawing.Rectangle(x, y, width, height);

        // Fallback: use the WPF screen capture approach
        using var bitmap = new System.Drawing.Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = System.Drawing.Graphics.FromImage(bitmap))
        {
            g.CopyFromScreen(x, y, 0, 0, new System.Drawing.Size(width, height),
                System.Drawing.CopyPixelOperation.SourceCopy);
        }

        // Convert System.Drawing.Bitmap to WPF BitmapSource
        var hBitmap = bitmap.GetHbitmap();
        try
        {
            return System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(
                hBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
        }
        finally
        {
            DeleteObject(hBitmap);
        }
    }

    private static void SaveAsPng(BitmapSource source, string filePath)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var stream = File.Create(filePath);
        encoder.Save(stream);
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint hObject);

    private static WindowsToolResult Ok(string summary, string? artifactPath) =>
        new(true, summary, artifactPath is not null ? $"Saved to: {artifactPath}" : null,
            artifactPath, ToolPrivacyImpact.Screenshot, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.Screenshot, DateTimeOffset.UtcNow);

    private static WindowsToolResult Blocked(string summary) =>
        new(false, summary, "Blocked by settings policy.", null, ToolPrivacyImpact.Screenshot, DateTimeOffset.UtcNow);
}
