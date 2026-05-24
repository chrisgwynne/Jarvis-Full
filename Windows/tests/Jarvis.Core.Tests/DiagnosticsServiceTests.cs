using FluentAssertions;
using Jarvis.Core.Diagnostics;
using Jarvis.Diagnostics;
using Xunit;

namespace Jarvis.Core.Tests;

public class DiagnosticsServiceTests
{
    [Fact]
    public void Ring_buffer_drops_oldest_when_full()
    {
        var diag = new DiagnosticsService(capacity: 3);
        diag.Record(DiagnosticLevel.Info, "t", "a");
        diag.Record(DiagnosticLevel.Info, "t", "b");
        diag.Record(DiagnosticLevel.Info, "t", "c");
        diag.Record(DiagnosticLevel.Info, "t", "d");

        var entries = diag.Recent();
        entries.Should().HaveCount(3);
        entries.Select(e => e.Message).Should().ContainInOrder("b", "c", "d");
    }

    [Fact]
    public void Metric_recording_overwrites_previous_value()
    {
        var diag = new DiagnosticsService();
        diag.RecordMetric("cpu.percent", 12.5);
        diag.RecordMetric("cpu.percent", 17.0);
        diag.Metrics["cpu.percent"].Should().Be(17.0);
    }

    [Fact]
    public void Recent_with_max_returns_tail_window()
    {
        var diag = new DiagnosticsService();
        for (var i = 0; i < 10; i++) diag.Record(DiagnosticLevel.Debug, "t", i.ToString());
        var tail = diag.Recent(max: 3);
        tail.Select(e => e.Message).Should().Equal("7", "8", "9");
    }
}
