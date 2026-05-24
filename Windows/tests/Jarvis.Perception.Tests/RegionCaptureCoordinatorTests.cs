using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Perception;
using Jarvis.Perception.Capture;
using Xunit;

namespace Jarvis.Perception.Tests;

public class RegionCaptureCoordinatorTests
{
    [Fact]
    public async Task Returns_null_when_ui_cancels()
    {
        var ui = new FakeUi(_ => Task.FromResult<RegionSelection?>(null));
        var grab = new FakeGrabber();
        var c = new RegionCaptureCoordinator(ui, grab);
        var result = await c.CaptureAsync();
        result.Should().BeNull();
        grab.Calls.Should().Be(0);
    }

    [Fact]
    public async Task Returns_result_with_png_bytes_when_ui_selects()
    {
        var sel = new RegionSelection(new Rect(10, 20, 110, 120), 0, 1.0);
        var ui = new FakeUi(_ => Task.FromResult<RegionSelection?>(sel));
        var grab = new FakeGrabber(new byte[] { 1, 2, 3 });
        var c = new RegionCaptureCoordinator(ui, grab);
        var result = await c.CaptureAsync();
        result.Should().NotBeNull();
        result!.PngBytes.Should().Equal(new byte[] { 1, 2, 3 });
        result.Width.Should().Be(100);
        result.Height.Should().Be(100);
        grab.Calls.Should().Be(1);
    }

    [Fact]
    public async Task Second_concurrent_call_returns_null()
    {
        var gate = new TaskCompletionSource<RegionSelection?>();
        var ui = new FakeUi(_ => gate.Task);
        var grab = new FakeGrabber();
        var c = new RegionCaptureCoordinator(ui, grab);
        var first = c.CaptureAsync();
        var second = await c.CaptureAsync();
        second.Should().BeNull();
        gate.SetResult(null);
        await first;
    }

    [Fact]
    public async Task Empty_selection_treated_as_cancel()
    {
        var sel = new RegionSelection(new Rect(0, 0, 0, 0), 0, 1.0);
        var ui = new FakeUi(_ => Task.FromResult<RegionSelection?>(sel));
        var grab = new FakeGrabber();
        var c = new RegionCaptureCoordinator(ui, grab);
        var raised = false;
        c.Cancelled += (_, _) => raised = true;
        var result = await c.CaptureAsync();
        result.Should().BeNull();
        raised.Should().BeTrue();
    }

    private sealed class FakeUi : IRegionSelectionUi
    {
        private readonly Func<CancellationToken, Task<RegionSelection?>> _f;
        public FakeUi(Func<CancellationToken, Task<RegionSelection?>> f) => _f = f;
        public Task<RegionSelection?> SelectAsync(CancellationToken cancellationToken = default) => _f(cancellationToken);
    }

    private sealed class FakeGrabber : IScreenGrabber
    {
        private readonly byte[] _bytes;
        public int Calls;
        public FakeGrabber(byte[]? bytes = null) => _bytes = bytes ?? Array.Empty<byte>();
        public byte[] CaptureToPng(RegionSelection selection) { Calls++; return _bytes; }
    }
}
