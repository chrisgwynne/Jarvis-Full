using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class GuidanceDebounceTests
{
    [Fact]
    public async Task Same_query_within_debounce_window_returns_cached_result()
    {
        var src = new CountingSource();
        var svc = BuildService(src);
        await svc.AskAsync("save");
        await svc.AskAsync("save");
        src.Calls.Should().Be(1, because: "the second call hit the debounce cache");
        svc.LastDiagnostics!.Suppressed.Should().BeTrue();
    }

    [Fact]
    public async Task Different_query_is_not_debounced()
    {
        var src = new CountingSource();
        var svc = BuildService(src);
        await svc.AskAsync("save");
        await svc.AskAsync("continue");
        src.Calls.Should().Be(2);
    }

    [Fact]
    public async Task New_query_cancels_in_flight()
    {
        // Use a blocking source rather than wall-clock delays: the first call waits
        // until _unblock is signalled (or its CancellationToken fires). This removes
        // the race where Task.Delay(50) can exceed the SlowSource delay on loaded CI.
        var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var unblock = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var src = new BlockingSource(started, unblock);
        var svc = BuildService(src);

        var first = svc.AskAsync("save");
        await started.Task;                                  // first is definitely in DiscoverAsync now
        var second = svc.AskAsync("continue");              // cancels first
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        unblock.TrySetResult(true);                         // let second's DiscoverAsync finish
        var result = await second;
        result.Query.Should().Be("continue");
    }

    [Fact]
    public async Task Diagnostics_record_per_source_latency_and_counts()
    {
        var src = new CountingSource();
        var svc = BuildService(src);
        await svc.AskAsync("save");
        var d = svc.LastDiagnostics!;
        d.SourceCandidateCounts.Should().ContainKey(TargetSource.UiAutomation);
        d.SourceLatencyMs.Should().ContainKey(TargetSource.UiAutomation);
        d.TotalMs.Should().BeGreaterThanOrEqualTo(0);
    }

    private static GuidanceService BuildService(IUiTargetSource source) => new(
        awareness: new StubAwareness(),
        browser: new StubBrowser(),
        highlighter: new NoopHighlighter(),
        sources: new[] { source },
        cursorReader: () => (0, 0));

    private sealed class CountingSource : IUiTargetSource
    {
        public int Calls;
        public TargetSource Source => TargetSource.UiAutomation;
        public Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext c, CancellationToken ct)
        {
            Calls++;
            IReadOnlyList<UiTarget> list = new[]
            {
                new UiTarget("Save", "button", new Rect(0, 0, 80, 24), 0.8, TargetSource.UiAutomation,
                    ActionHint: "click", Enabled: true)
            };
            return Task.FromResult(list);
        }
    }

    /// <summary>
    /// Signals <paramref name="started"/> when DiscoverAsync is entered, then blocks until
    /// <paramref name="unblock"/> is set OR the CancellationToken fires — whichever comes first.
    /// This removes wall-clock timing from the cancellation test.
    /// </summary>
    private sealed class BlockingSource : IUiTargetSource
    {
        private readonly TaskCompletionSource<bool> _started;
        private readonly TaskCompletionSource<bool> _unblock;

        public BlockingSource(TaskCompletionSource<bool> started, TaskCompletionSource<bool> unblock)
        {
            _started = started;
            _unblock = unblock;
        }

        public TargetSource Source => TargetSource.UiAutomation;

        public async Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext c, CancellationToken ct)
        {
            _started.TrySetResult(true);
            await _unblock.Task.WaitAsync(ct);
            return Array.Empty<UiTarget>();
        }
    }

    private sealed class StubAwareness : IDesktopAwarenessService
    {
        public DesktopSnapshot? Latest => new(DateTimeOffset.UtcNow, "test", "T", (IntPtr)1, 0,
            new Rect(0, 0, 800, 600), TimeSpan.Zero, true);
        public event EventHandler<DesktopSnapshot>? SnapshotChanged { add { } remove { } }
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class StubBrowser : IBrowserContext
    {
        public BrowserContextSnapshot Current => BrowserContextSnapshot.Empty;
        public bool IsConnected => false;
        public event EventHandler<BrowserContextSnapshot>? Updated { add { } remove { } }
    }

    private sealed class NoopHighlighter : Jarvis.Core.Automation.IHighlightRenderer
    {
        public Task ShowAsync(int x, int y, int width, int height, string? label, TimeSpan duration, CancellationToken cancellationToken = default) =>
            Task.CompletedTask;
    }
}
