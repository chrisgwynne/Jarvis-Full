using FluentAssertions;
using Jarvis.Automation;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class JsonlAuditLogTests : IDisposable
{
    private readonly string _dir;

    public JsonlAuditLogTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "jarvis-audit-" + Guid.NewGuid().ToString("N"));
    }

    [Fact]
    public async Task Append_writes_one_jsonl_line()
    {
        var log = new JsonlAuditLog(_dir);
        var entry = new AuditEntry(
            DateTimeOffset.UtcNow, "test.kind", "test summary",
            SafetyTier.Safe, "test reason",
            AutomationOutcome.Succeeded, "msg", "undo", 1.5, "tester");
        await log.AppendAsync(entry);
        var file = Directory.GetFiles(_dir, "*.jsonl").Single();
        var lines = await File.ReadAllLinesAsync(file);
        lines.Should().HaveCount(1);
        lines[0].Should().Contain("\"test.kind\"");
        lines[0].Should().Contain("\"Succeeded\"");
    }

    [Fact]
    public async Task Recent_returns_in_memory_tail()
    {
        var log = new JsonlAuditLog(_dir);
        for (var i = 0; i < 5; i++)
        {
            await log.AppendAsync(new AuditEntry(
                DateTimeOffset.UtcNow, $"k{i}", "s", SafetyTier.Safe, null,
                AutomationOutcome.Succeeded, null, null, 0, null));
        }
        var recent = log.Recent(3);
        recent.Should().HaveCount(3);
        recent.Select(e => e.IntentKind).Should().Equal("k2", "k3", "k4");
    }

    [Fact]
    public async Task Multiple_appends_create_one_file_per_day()
    {
        var log = new JsonlAuditLog(_dir);
        var d = new DateTimeOffset(2026, 5, 23, 0, 0, 0, TimeSpan.Zero);
        await log.AppendAsync(new AuditEntry(d, "k", "s", SafetyTier.Safe, null, AutomationOutcome.Succeeded, null, null, 0, null));
        await log.AppendAsync(new AuditEntry(d.AddHours(2), "k", "s", SafetyTier.Safe, null, AutomationOutcome.Succeeded, null, null, 0, null));
        Directory.GetFiles(_dir, "*.jsonl").Should().HaveCount(1);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}
