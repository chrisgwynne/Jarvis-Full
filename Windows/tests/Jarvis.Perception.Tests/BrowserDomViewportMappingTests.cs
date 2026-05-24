using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class BrowserDomViewportMappingTests
{
    // The browser sends rects in CSS pixels relative to the viewport. Host needs to map
    // those to physical screen pixels by:
    //   screen = (viewport.ScreenX + rect.X) * dpr
    // These tests pin that behaviour at the DPR scales we care about.

    [Theory]
    [InlineData(1.0,  "1x scale, integer ratio")]
    [InlineData(1.25, "125% Windows scaling")]
    [InlineData(1.5,  "150% scaling")]
    [InlineData(2.0,  "Retina-style 2x")]
    public void Maps_a_simple_rect_at_each_DPR(double dpr, string note)
    {
        // Viewport: starts at logical (300, 200), 1000×800 CSS px.
        var viewport = new BrowserViewport(
            ScreenX: 300, ScreenY: 200, Width: 1000, Height: 800,
            DevicePixelRatio: dpr, ScrollX: 0, ScrollY: 0);
        var targets = new[]
        {
            new BrowserDomTarget("Save", "button", "#save", X: 100, Y: 50, Width: 80, Height: 24, Visible: true, Enabled: true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport, windowBounds: Rect.Empty, process: "chrome");
        result.Should().HaveCount(1, because: note);
        var t = result[0];
        // (300 + 100) * dpr = 400 * dpr  →  X
        t.Bounds.Left.Should().Be((int)Math.Round((300 + 100) * dpr));
        t.Bounds.Top.Should().Be((int)Math.Round((200 + 50) * dpr));
        t.Bounds.Width.Should().Be((int)Math.Round(80 * dpr));
        t.Bounds.Height.Should().Be((int)Math.Round(24 * dpr));
    }

    [Fact]
    public void Fullscreen_viewport_drops_chrome_offset()
    {
        // F11 fullscreen: viewport occupies the whole window, ScreenY = top of monitor.
        var viewport = new BrowserViewport(ScreenX: 0, ScreenY: 0, Width: 1920, Height: 1080,
            DevicePixelRatio: 1.0, ScrollX: 0, ScrollY: 0);
        var targets = new[]
        {
            new BrowserDomTarget("Continue", "button", "#go", 12, 20, 100, 32, true, true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport, windowBounds: Rect.Empty, process: null);
        result[0].Bounds.Top.Should().Be(20, because: "fullscreen viewport has no chrome offset");
    }

    [Fact]
    public void Secondary_monitor_with_negative_screenX_maps_correctly()
    {
        // Secondary monitor to the left of the primary, so ScreenX is negative.
        var viewport = new BrowserViewport(ScreenX: -1920, ScreenY: 200, Width: 1600, Height: 900,
            DevicePixelRatio: 1.0, ScrollX: 0, ScrollY: 0);
        var targets = new[]
        {
            new BrowserDomTarget("Save", "button", "#s", X: 500, Y: 100, Width: 80, Height: 24, Visible: true, Enabled: true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport, windowBounds: Rect.Empty, process: null);
        result[0].Bounds.Left.Should().Be(-1920 + 500);
        result[0].Bounds.Right.Should().Be(-1920 + 500 + 80);
    }

    [Fact]
    public void Fallback_used_when_viewport_missing()
    {
        var window = new Rect(200, 100, 1400, 1000);
        var targets = new[]
        {
            new BrowserDomTarget("Save", "button", "#save", X: 50, Y: 80, Width: 90, Height: 32, Visible: true, Enabled: true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport: null, window, "chrome");
        // Fallback adds 104 px of chrome to window.Top.
        result[0].Bounds.Top.Should().Be(window.Top + 104 + 80);
    }

    [Fact]
    public void Targets_below_the_fold_are_clipped_out()
    {
        var viewport = new BrowserViewport(0, 0, 800, 600, 1.0, 0, 0);
        var targets = new[]
        {
            new BrowserDomTarget("Above fold", "button", "#a", X: 10, Y: 10, Width: 80, Height: 24, Visible: true, Enabled: true),
            new BrowserDomTarget("Below fold", "button", "#b", X: 10, Y: 700, Width: 80, Height: 24, Visible: true, Enabled: true),
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport, Rect.Empty, null);
        result.Should().HaveCount(1);
        result[0].Label.Should().Be("Above fold");
    }
}
