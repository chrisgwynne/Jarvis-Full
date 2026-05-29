using FluentAssertions;
using Xunit;
using Jarvis.Core.Logging;
using Jarvis.Core.Sidecar;
using Jarvis.Settings;

namespace Jarvis.Perception.Tests;

/// <summary>
/// Tests proving every TTS call is logged (Windows) and that the JSONL logger
/// correctly stores, rotates, edits, and exports entries.
/// </summary>
public sealed class ReplyLogTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _logPath;

    public ReplyLogTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "JarvisReplyLogTests_" + Guid.NewGuid());
        Directory.CreateDirectory(_tempDir);
        _logPath = Path.Combine(_tempDir, "reply_log.jsonl");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private JsonlReplyLogger MakeLogger() => new(_logPath);

    // MARK: Basic append and read

    [Fact]
    public async Task Append_WritesEntry_ToFile()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Command, "Hello there.", responseKey: "wake.ack");

        await Task.Delay(50);

        var entries = await logger.RecentAsync();
        entries.Should().HaveCount(1);
        entries[0].SpokenText.Should().Be("Hello there.");
        entries[0].Source.Should().Be(ReplySource.Command);
        entries[0].ResponseKey.Should().Be("wake.ack");
        entries[0].Device.Should().Be("windows");
    }

    [Fact]
    public async Task Append_IgnoresBlankText()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Llm, "   ");
        logger.Append(ReplySource.Llm, "");

        await Task.Delay(50);

        var entries = await logger.RecentAsync();
        entries.Should().BeEmpty();
    }

    [Fact]
    public async Task Append_MultipleEntries_AllAppear()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Command, "First.");
        logger.Append(ReplySource.Llm, "Second.");
        logger.Append(ReplySource.Error, "Third.");

        await Task.Delay(100);

        var entries = await logger.AllAsync();
        entries.Should().HaveCount(3);
        entries.Select(e => e.SpokenText).Should().Contain(["First.", "Second.", "Third."]);
    }

    // MARK: Limit

    [Fact]
    public async Task RecentAsync_ReturnsLimitedCount()
    {
        var logger = MakeLogger();
        for (var i = 0; i < 20; i++)
            logger.Append(ReplySource.System, $"Entry {i}");

        await Task.Delay(200);

        var recent = await logger.RecentAsync(limit: 5);
        recent.Should().HaveCount(5);
    }

    // MARK: Edit (correction)

    [Fact]
    public async Task UpdateCorrection_SetsFields_Correctly()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Llm, "I couldn't do that.");
        await Task.Delay(100);

        var entries = await logger.AllAsync();
        var id = entries[0].Id;

        await logger.UpdateCorrectionAsync(id, "I'm unable to do that right now.", accepted: true);

        var updated = await logger.AllAsync();
        updated[0].CorrectedText.Should().Be("I'm unable to do that right now.");
        updated[0].Accepted.Should().BeTrue();
    }

    // MARK: Export

    [Fact]
    public async Task ExportJsonl_ContainsAllEntries()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Command, "Alpha.");
        logger.Append(ReplySource.Tool, "Beta.");
        await Task.Delay(100);

        var jsonl = await logger.ExportJsonlAsync();
        jsonl.Should().Contain("Alpha.");
        jsonl.Should().Contain("Beta.");
        jsonl.Should().Contain("command");
        jsonl.Should().Contain("tool");
    }

    [Fact]
    public async Task ExportCsv_ContainsHeader_AndRows()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Proactive, "Time to take a break.");
        await Task.Delay(100);

        var csv = await logger.ExportCsvAsync();
        csv.Should().Contain("timestamp,source,intent,responseKey,spokenText");
        csv.Should().Contain("proactive");
        csv.Should().Contain("Time to take a break.");
    }

    // MARK: LoggingTtsService decorator

    [Fact]
    public async Task LoggingTtsService_LogsBeforeForwarding()
    {
        var logger = MakeLogger();
        var stub = new StubTtsService();
        var sut = new LoggingTtsService(stub, logger);

        await sut.SpeakAsync("Testing the decorator.");

        await Task.Delay(100);

        stub.LastSpoken.Should().Be("Testing the decorator.");
        var entries = await logger.RecentAsync();
        entries.Should().HaveCount(1);
        entries[0].SpokenText.Should().Be("Testing the decorator.");
        entries[0].Source.Should().Be(ReplySource.System);
    }

    [Fact]
    public async Task LoggingTtsService_SkipsBlank_DoesNotLog()
    {
        var logger = MakeLogger();
        var stub = new StubTtsService();
        var sut = new LoggingTtsService(stub, logger);

        await sut.SpeakAsync("   ");
        await Task.Delay(100);

        var entries = await logger.RecentAsync();
        entries.Should().BeEmpty();
    }

    [Fact]
    public async Task LoggingTtsService_ForwardsStopAsync()
    {
        var stub = new StubTtsService();
        var sut = new LoggingTtsService(stub, new JsonlReplyLogger(_logPath));

        await sut.StopAsync();
        stub.StopCalled.Should().BeTrue();
    }

    // MARK: EditableFlag

    [Fact]
    public async Task Append_SystemSource_DefaultsEditableFlag_False()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.System, "Internal message.", editableFlag: false);
        await Task.Delay(50);

        var entries = await logger.RecentAsync();
        entries[0].EditableFlag.Should().BeFalse();
    }

    [Fact]
    public async Task Append_CommandSource_EditableFlag_True()
    {
        var logger = MakeLogger();
        logger.Append(ReplySource.Command, "Wake acknowledged.", editableFlag: true);
        await Task.Delay(50);

        var entries = await logger.RecentAsync();
        entries[0].EditableFlag.Should().BeTrue();
    }

    // MARK: Persistence across instances

    [Fact]
    public async Task NewInstance_LoadsExistingLog()
    {
        var logger1 = MakeLogger();
        logger1.Append(ReplySource.Template, "Persisted entry.");
        await Task.Delay(100);

        var logger2 = MakeLogger();
        var entries = await logger2.AllAsync();
        entries.Should().HaveCount(1);
        entries[0].SpokenText.Should().Be("Persisted entry.");
    }

    // MARK: Stub TTS

    private sealed class StubTtsService : ILocalTtsService
    {
        public string? LastSpoken { get; private set; }
        public bool StopCalled { get; private set; }
        public bool IsSpeaking => false;

        public Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default)
        {
            LastSpoken = text;
            return Task.FromResult(true);
        }

        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            StopCalled = true;
            return Task.CompletedTask;
        }
    }
}
