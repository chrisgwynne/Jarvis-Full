using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class OcrTargetSourceTests
{
    [Fact]
    public void GuessRole_classifies_short_labels_as_buttons()
    {
        OcrTargetSource.GuessRole("Save").Should().Be("button");
        OcrTargetSource.GuessRole("Save changes").Should().Be("button");
        OcrTargetSource.GuessRole("Lorem ipsum dolor sit amet consectetur adipiscing elit").Should().Be("text");
    }

    [Fact]
    public async Task Returns_empty_when_allow_ocr_false()
    {
        var src = new OcrTargetSource(_ => Task.FromResult<byte[]?>(null), new FakeOcr(true));
        var result = await src.DiscoverAsync(MakeContext(allowOcr: false), CancellationToken.None);
        result.Should().BeEmpty();
    }

    [Fact]
    public async Task Returns_empty_when_ocr_unavailable()
    {
        var src = new OcrTargetSource(_ => Task.FromResult<byte[]?>(new byte[10]), new FakeOcr(false));
        var result = await src.DiscoverAsync(MakeContext(allowOcr: true), CancellationToken.None);
        result.Should().BeEmpty();
    }

    [Fact]
    public async Task Returns_empty_when_grab_returns_null()
    {
        var src = new OcrTargetSource(_ => Task.FromResult<byte[]?>(null), new FakeOcr(true));
        var result = await src.DiscoverAsync(MakeContext(allowOcr: true), CancellationToken.None);
        result.Should().BeEmpty();
    }

    [Fact]
    public async Task Translates_ocr_lines_to_screen_coords()
    {
        var fakeOcr = new FakeOcr(available: true, lines: new[]
        {
            new OcrLine("Save", new[] { new OcrWord("Save", 1.0, new OcrRect(10, 20, 40, 16)) })
        });
        var src = new OcrTargetSource(_ => Task.FromResult<byte[]?>(new byte[10]), fakeOcr);
        var ctx = MakeContext(allowOcr: true, fg: new Rect(200, 100, 1200, 800));
        var result = await src.DiscoverAsync(ctx, CancellationToken.None);
        result.Should().HaveCount(1);
        var t = result[0];
        t.Bounds.Left.Should().Be(210);  // 200 + 10
        t.Bounds.Top.Should().Be(120);   // 100 + 20
        t.Bounds.Width.Should().Be(40);
        t.Bounds.Height.Should().Be(16);
        t.Confidence.Should().BeLessThan(0.5, "OCR is the least-trusted source");
    }

    private static TargetDiscoveryContext MakeContext(bool allowOcr, Rect? fg = null) => new(
        Query: null, ForegroundProcess: "test", ForegroundWindowTitle: null,
        ForegroundWindowHandle: (IntPtr)1,
        ForegroundWindowBounds: fg ?? new Rect(0, 0, 1000, 800),
        CursorX: 0, CursorY: 0,
        BrowserConnected: false, AllowOcrFallback: allowOcr);

    private sealed class FakeOcr : IOcrService
    {
        private readonly IReadOnlyList<OcrLine> _lines;
        public FakeOcr(bool available, IReadOnlyList<OcrLine>? lines = null)
        { IsAvailable = available; _lines = lines ?? Array.Empty<OcrLine>(); }
        public bool IsAvailable { get; }
        public Task<OcrResult> RecognizeAsync(byte[] pngBytes, CancellationToken cancellationToken = default) =>
            Task.FromResult(new OcrResult(DateTimeOffset.UtcNow, string.Join("\n", _lines.Select(l => l.Text)),
                "en-GB", _lines, TimeSpan.Zero, 1.0));
    }
}
