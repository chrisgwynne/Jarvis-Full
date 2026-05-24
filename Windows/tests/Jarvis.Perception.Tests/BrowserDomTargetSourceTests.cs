using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class BrowserDomTargetSourceTests
{
    [Fact]
    public void ConvertTargets_maps_viewport_to_screen_coords()
    {
        var window = new Rect(200, 100, 1400, 1000); // 1200 wide, 900 tall
        var targets = new[]
        {
            new BrowserDomTarget("Save", "button", "button#save", X: 50, Y: 80, Width: 90, Height: 32, Visible: true, Enabled: true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport: null, window, "chrome");
        result.Should().HaveCount(1);
        var t = result[0];
        // window.left + 0 (left chrome) + 50 = 250
        t.Bounds.Left.Should().Be(250);
        // window.top + 104 (top chrome) + 80 = 284
        t.Bounds.Top.Should().Be(284);
        t.Bounds.Width.Should().Be(90);
        t.Bounds.Height.Should().Be(32);
        t.Selector.Should().Be("button#save");
        t.Process.Should().Be("chrome");
    }

    [Fact]
    public void ConvertTargets_drops_invisible_targets()
    {
        var targets = new[]
        {
            new BrowserDomTarget("Hidden", "button", "x", 10, 10, 80, 24, Visible: false, Enabled: true),
            new BrowserDomTarget("Shown", "button", "y", 10, 50, 80, 24, Visible: true, Enabled: true)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport: null, new Rect(0, 0, 800, 600), null);
        result.Should().HaveCount(1);
        result[0].Label.Should().Be("Shown");
    }

    [Fact]
    public void ConvertTargets_drops_empty_labels()
    {
        var targets = new[]
        {
            new BrowserDomTarget("", "button", "x", 0, 0, 80, 24, true, true),
            new BrowserDomTarget("  ", "button", "y", 0, 30, 80, 24, true, true)
        };
        BrowserDomTargetSource.ConvertTargets(targets, viewport: null, new Rect(0, 0, 800, 600), null).Should().BeEmpty();
    }

    [Fact]
    public void ConvertTargets_drops_zero_sized_targets()
    {
        var targets = new[]
        {
            new BrowserDomTarget("Edge case", "button", "x", 0, 0, 0, 0, true, true),
            new BrowserDomTarget("Edge case 2", "button", "y", 0, 0, 1, 1, true, true)
        };
        BrowserDomTargetSource.ConvertTargets(targets, viewport: null, new Rect(0, 0, 800, 600), null).Should().BeEmpty();
    }

    [Fact]
    public void Disabled_target_gets_lower_confidence()
    {
        var targets = new[]
        {
            new BrowserDomTarget("Enabled", "button", "a", 0, 0, 80, 24, true, true),
            new BrowserDomTarget("Disabled", "button", "b", 100, 0, 80, 24, true, false)
        };
        var result = BrowserDomTargetSource.ConvertTargets(targets, viewport: null, new Rect(0, 0, 800, 600), null);
        result.Should().HaveCount(2);
        var disabled = result.Single(t => t.Label == "Disabled");
        disabled.Enabled.Should().BeFalse();
        disabled.Confidence.Should().BeLessThan(result.Single(t => t.Label == "Enabled").Confidence);
    }
}
