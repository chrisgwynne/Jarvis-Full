using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class GuidanceServiceTests
{
    [Fact]
    public async Task Best_target_drives_highlight_and_suggested_click()
    {
        var save = MakeTarget("Save", "button", TargetSource.UiAutomation, x: 200, y: 100, w: 80, h: 24);
        var open = MakeTarget("Open", "button", TargetSource.UiAutomation, x: 600, y: 100, w: 80, h: 24);
        var (svc, highlighter) = BuildService(new[] { save, open });

        var result = await svc.AskAsync("save this");

        result.Found.Should().BeTrue();
        result.Best!.Label.Should().Be("Save");
        result.SuggestedClick.Should().NotBeNull();
        result.SuggestedClick!.X.Should().Be(240); // center of (200..280)
        result.SuggestedClick.Y.Should().Be(112);
        highlighter.Calls.Should().Be(1);
        highlighter.LastLabel.Should().Contain("Save");
        svc.LastHighlighted.Should().Be(save);
    }

    [Fact]
    public async Task No_targets_returns_not_found()
    {
        var (svc, _) = BuildService(Array.Empty<UiTarget>());
        var result = await svc.AskAsync("save");
        result.Found.Should().BeFalse();
        result.SuggestedClick.Should().BeNull();
        result.Explanation.Should().Contain("couldn't see");
    }

    [Fact]
    public async Task Low_confidence_does_not_highlight_or_suggest_click()
    {
        // Label unrelated to query → low score
        var t = MakeTarget("Profile", "button", TargetSource.Ocr, confidence: 0.3);
        var (svc, highlighter) = BuildService(new[] { t });
        var result = await svc.AskAsync("save the document");
        result.LowConfidence.Should().BeTrue();
        result.SuggestedClick.Should().BeNull();
        highlighter.Calls.Should().Be(0);
    }

    [Fact]
    public async Task Clear_drops_last_highlight()
    {
        var t = MakeTarget("Save", "button", TargetSource.UiAutomation);
        var (svc, _) = BuildService(new[] { t });
        await svc.AskAsync("save");
        svc.LastHighlighted.Should().NotBeNull();
        svc.Clear();
        svc.LastHighlighted.Should().BeNull();
    }

    [Fact]
    public async Task OCR_fallback_runs_only_when_UIA_returns_few_targets()
    {
        var uia = MakeSource(TargetSource.UiAutomation, new[] {
            MakeTarget("Foo", "button", TargetSource.UiAutomation)
        });
        var ocr = MakeSource(TargetSource.Ocr, new[] {
            MakeTarget("Save", "button", TargetSource.Ocr, confidence: 0.4)
        });
        var (svc, _) = BuildServiceFromSources(new[] { uia, ocr });
        await svc.AskAsync("save");
        // UIA returned 1 (< 3), so OCR fires.
        ocr.CallCount.Should().Be(1);
    }

    [Fact]
    public async Task OCR_fallback_skipped_when_browser_dom_returns_targets()
    {
        var browser = MakeSource(TargetSource.BrowserDom, new[] {
            MakeTarget("Continue", "button", TargetSource.BrowserDom)
        });
        var ocr = MakeSource(TargetSource.Ocr, new[] { MakeTarget("Whatever", "button", TargetSource.Ocr) });
        var (svc, _) = BuildServiceFromSources(new[] { browser, ocr }, browserConnected: true);
        await svc.AskAsync("continue");
        ocr.CallCount.Should().Be(0);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static UiTarget MakeTarget(string label, string role, TargetSource source,
        int x = 100, int y = 100, int w = 80, int h = 24, double confidence = 0.8) =>
        new(label, role, new Rect(x, y, x + w, y + h), confidence, source,
            ActionHint: "click", Enabled: true);

    private static (GuidanceService, FakeHighlighter) BuildService(IReadOnlyList<UiTarget> targets, bool browserConnected = false)
    {
        var fake = new FakeSource(TargetSource.UiAutomation, targets);
        return BuildServiceFromSources(new[] { fake }, browserConnected);
    }

    private static (GuidanceService, FakeHighlighter) BuildServiceFromSources(
        IReadOnlyList<IUiTargetSource> sources, bool browserConnected = false)
    {
        var highlighter = new FakeHighlighter();
        var svc = new GuidanceService(
            awareness: new FakeAwareness(),
            browser: new FakeBrowserContext(browserConnected),
            highlighter: highlighter,
            sources: sources,
            cursorReader: () => (240, 112));
        return (svc, highlighter);
    }

    private static FakeSource MakeSource(TargetSource src, IReadOnlyList<UiTarget> targets) =>
        new(src, targets);

    private sealed class FakeSource : IUiTargetSource
    {
        private readonly IReadOnlyList<UiTarget> _targets;
        public int CallCount;
        public FakeSource(TargetSource src, IReadOnlyList<UiTarget> targets) { Source = src; _targets = targets; }
        public TargetSource Source { get; }
        public Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext context, CancellationToken cancellationToken)
        { CallCount++; return Task.FromResult(_targets); }
    }

    private sealed class FakeHighlighter : IHighlightRenderer
    {
        public int Calls;
        public string? LastLabel;
        public Task ShowAsync(int x, int y, int width, int height, string? label, TimeSpan duration, CancellationToken cancellationToken = default)
        { Calls++; LastLabel = label; return Task.CompletedTask; }
    }

    private sealed class FakeAwareness : IDesktopAwarenessService
    {
        public DesktopSnapshot? Latest => new(DateTimeOffset.UtcNow, "Code", "main.cs - Visual Studio Code",
            (IntPtr)1, 0, new Rect(0, 0, 1920, 1080), TimeSpan.Zero, true);
        public event EventHandler<DesktopSnapshot>? SnapshotChanged { add { } remove { } }
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeBrowserContext : IBrowserContext
    {
        public FakeBrowserContext(bool connected) { IsConnected = connected; }
        public BrowserContextSnapshot Current => BrowserContextSnapshot.Empty;
        public bool IsConnected { get; }
        public event EventHandler<BrowserContextSnapshot>? Updated { add { } remove { } }
    }
}
