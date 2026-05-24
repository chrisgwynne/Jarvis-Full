using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using FluentAssertions;
using Jarvis.Perception.Ocr;
using Xunit;
using Xunit.Abstractions;

namespace Jarvis.Perception.Tests;

/// <summary>
/// Smoke / accuracy / latency check against the real Windows.Media.Ocr engine.
/// Skipped automatically when no OCR language pack is installed on the host.
/// </summary>
public class WindowsOcrIntegrationTests
{
    private readonly ITestOutputHelper _output;
    public WindowsOcrIntegrationTests(ITestOutputHelper output) => _output = output;

    private static byte[] RenderText(string text, int width, int height, float fontSize = 36f)
    {
        using var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.White);
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var font = new Font("Segoe UI", fontSize, FontStyle.Regular, GraphicsUnit.Pixel);
            g.DrawString(text, font, Brushes.Black, new PointF(12, 12));
        }
        using var ms = new MemoryStream();
        bmp.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    }

    [Fact]
    public async Task Recognizes_short_phrase_when_engine_available()
    {
        var svc = new WindowsOcrService(new OcrPostProcessor());
        if (!svc.IsAvailable)
        {
            _output.WriteLine("Skipped: no Windows OCR language pack installed.");
            return;
        }
        var png = RenderText("Hello world", 600, 120);
        var sw = Stopwatch.StartNew();
        var result = await svc.RecognizeAsync(png);
        sw.Stop();
        _output.WriteLine($"text='{result.Text}' duration={result.Duration.TotalMilliseconds:F0}ms lang={result.Language}");
        result.Text.Should().Contain("Hello", because: "first word should round-trip");
        result.Text.Should().Contain("world", because: "second word should round-trip");
        result.Duration.TotalSeconds.Should().BeLessThan(1.0, because: "P2 budget for a small region");
    }

    [Fact]
    public async Task Recognizes_code_like_text()
    {
        var svc = new WindowsOcrService(new OcrPostProcessor());
        if (!svc.IsAvailable)
        {
            _output.WriteLine("Skipped: no Windows OCR language pack installed.");
            return;
        }
        var png = RenderText("var x = 42;", 600, 120, 32f);
        var result = await svc.RecognizeAsync(png);
        _output.WriteLine($"text='{result.Text}' duration={result.Duration.TotalMilliseconds:F0}ms");
        result.Text.Length.Should().BeGreaterThan(0);
    }

    [Fact]
    public async Task Empty_input_returns_empty()
    {
        var svc = new WindowsOcrService(new OcrPostProcessor());
        var result = await svc.RecognizeAsync(Array.Empty<byte>());
        result.Text.Should().BeEmpty();
    }
}
