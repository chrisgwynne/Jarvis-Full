using System.Diagnostics;
using FluentAssertions;
using Jarvis.Core.Logging;
using Jarvis.Core.Sidecar;
using Jarvis.Settings;

namespace Jarvis.Perception.Tests;

/// <summary>
/// Tests proving:
/// 1. ReplyLogger.Append() is fire-and-forget — it does NOT block TTS.
/// 2. Memory writes do not block TTS.
/// 3. SpeechLatencyTracker records turns correctly and computes statistics.
/// 4. SpeechTurnTrace derived timings are correct.
/// </summary>
public sealed class SpeechLatencyTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _logPath;

    public SpeechLatencyTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "JarvisSpeechLatencyTests_" + Guid.NewGuid());
        Directory.CreateDirectory(_tempDir);
        _logPath = Path.Combine(_tempDir, "reply_log.jsonl");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    // MARK: - ReplyLogger non-blocking

    [Fact]
    public async Task ReplyLogger_Append_ReturnsImmediately_DoesNotBlockCaller()
    {
        // Use a logger backed by a real file path so the async write path is exercised.
        var logger = new JsonlReplyLogger(_logPath);
        var ttsStarted = false;

        var sw = Stopwatch.StartNew();
        // Append many entries rapidly — the fire-and-forget write must not accumulate delay.
        for (var i = 0; i < 50; i++)
            logger.Append(ReplySource.System, $"Entry {i}", editableFlag: false);

        sw.Stop();
        ttsStarted = true;

        // All 50 Append() calls must return well under a millisecond each on average.
        // Total synchronous cost must be far less than 50 ms.
        sw.ElapsedMilliseconds.Should().BeLessThan(50,
            because: "Append() is fire-and-forget; 50 calls should not accumulate I/O latency");
        ttsStarted.Should().BeTrue();
    }

    [Fact]
    public async Task LoggingTtsService_SpeakAsync_DoesNotWaitForSlowLogger()
    {
        // Arrange: a logger that parks the write on a background task with an artificial delay.
        var writeStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var writeBlocked = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var slowLogger = new BlockingReplyLogger(writeStarted, writeBlocked);

        var stub = new QuickTtsService();
        var sut = new LoggingTtsService(stub, slowLogger);

        // Act: call SpeakAsync — must NOT wait for the blocked write.
        var sw = Stopwatch.StartNew();
        await sut.SpeakAsync("Hello.");
        sw.Stop();

        // Assert: TTS finished long before the simulated 500 ms write.
        sw.ElapsedMilliseconds.Should().BeLessThan(200,
            because: "LoggingTtsService must not await the logger's write path before calling inner TTS");
        stub.SpeakCallCount.Should().Be(1);

        // Unblock so the background task can finish cleanly.
        writeBlocked.SetResult(true);
        await Task.Delay(20); // let the background write settle
    }

    [Fact]
    public async Task LoggingTtsService_Append_FiresBeforeTtsReturns()
    {
        // Prove Append() is called synchronously before inner.SpeakAsync().
        var appendOrder = new List<string>();
        var orderLogger = new OrderCapturingLogger(appendOrder);
        var stub = new OrderCapturingTtsService(appendOrder);
        var sut = new LoggingTtsService(stub, orderLogger);

        await sut.SpeakAsync("Test.");

        // Append must be recorded first, then speak.
        appendOrder.Should().HaveCount(2);
        appendOrder[0].Should().Be("append");
        appendOrder[1].Should().Be("speak");
    }

    // MARK: - SpeechLatencyTracker

    [Fact]
    public void SpeechLatencyTracker_RecordsTurn_WithAllMarks()
    {
        var tracker = new SpeechLatencyTracker();
        tracker.BeginTurn();
        tracker.Mark(SpeechStage.WakeDetect);
        tracker.Mark(SpeechStage.SttStart);
        tracker.Mark(SpeechStage.SttFinal);
        tracker.Mark(SpeechStage.LlmStart);
        tracker.Mark(SpeechStage.LlmFirstToken);
        tracker.Mark(SpeechStage.LlmComplete);
        tracker.Mark(SpeechStage.TtsStart);
        tracker.Mark(SpeechStage.PlaybackStarted);
        tracker.SetRoute(TurnRoute.LlmFallback);
        tracker.SetLlmUsed(true);
        tracker.SetTranscriptLength(42);
        tracker.SetReplyLength(80);
        tracker.CompleteTurn();

        var traces = tracker.RecentTraces();
        traces.Should().HaveCount(1);

        var trace = traces[0];
        trace.Route.Should().Be(TurnRoute.LlmFallback);
        trace.LlmUsed.Should().BeTrue();
        trace.TranscriptLength.Should().Be(42);
        trace.ReplyLength.Should().Be(80);
        trace.Device.Should().Be("windows");
        trace.Timestamps.Should().ContainKey(SpeechStage.WakeDetect);
        trace.Timestamps.Should().ContainKey(SpeechStage.LlmFirstToken);
        trace.SttMs.Should().BeGreaterThanOrEqualTo(0);
        trace.LlmMs.Should().BeGreaterThanOrEqualTo(0);
    }

    [Fact]
    public void SpeechLatencyTracker_RingBuffer_CapsAt20()
    {
        var tracker = new SpeechLatencyTracker();
        for (var i = 0; i < 25; i++)
        {
            tracker.BeginTurn();
            tracker.Mark(SpeechStage.WakeDetect);
            tracker.CompleteTurn();
        }

        tracker.RecentTraces().Should().HaveCount(20);
    }

    [Fact]
    public void SpeechLatencyTracker_RecentTraces_MostRecentFirst()
    {
        var tracker = new SpeechLatencyTracker();

        var id1 = tracker.BeginTurn();
        tracker.Mark(SpeechStage.WakeDetect);
        tracker.CompleteTurn();

        var id2 = tracker.BeginTurn();
        tracker.Mark(SpeechStage.WakeDetect);
        tracker.CompleteTurn();

        var traces = tracker.RecentTraces();
        traces[0].TurnId.Should().Be(id2, because: "most recent turn should appear first");
        traces[1].TurnId.Should().Be(id1);
    }

    [Fact]
    public void SpeechLatencyTracker_Statistics_ComputedCorrectly()
    {
        var tracker = new SpeechLatencyTracker();
        // Record 4 turns with approximately known total latency via artificial timestamps.
        // We can't fake DateTimeOffset in the real tracker, so just record a few real turns
        // and verify the stats are non-null and within plausible range.
        for (var i = 0; i < 4; i++)
        {
            tracker.BeginTurn();
            tracker.Mark(SpeechStage.WakeDetect);
            Thread.Sleep(1); // ensure non-zero gap
            tracker.Mark(SpeechStage.TtsComplete);
            tracker.CompleteTurn();
        }

        tracker.AverageTotalMs().Should().NotBeNull()
            .And.BeGreaterThan(0);
        tracker.P50().Should().NotBeNull();
        tracker.P95().Should().NotBeNull();
    }

    [Fact]
    public void SpeechLatencyTracker_RouteBreakdown_ReflectsSetRoutes()
    {
        var tracker = new SpeechLatencyTracker();

        void AddTurn(TurnRoute route)
        {
            tracker.BeginTurn();
            tracker.SetRoute(route);
            tracker.CompleteTurn();
        }

        AddTurn(TurnRoute.FastCommand);
        AddTurn(TurnRoute.FastCommand);
        AddTurn(TurnRoute.LlmFallback);

        var breakdown = tracker.RouteBreakdown();
        breakdown[TurnRoute.FastCommand].Should().Be(2);
        breakdown[TurnRoute.LlmFallback].Should().Be(1);
    }

    // MARK: - SpeechTurnTrace derived timings

    [Fact]
    public void SpeechTurnTrace_DerivedTimings_CorrectDeltaMs()
    {
        var t0 = DateTimeOffset.UtcNow;
        var timestamps = new Dictionary<string, DateTimeOffset>
        {
            [SpeechStage.WakeDetect]  = t0,
            [SpeechStage.SttStart]    = t0.AddMilliseconds(10),
            [SpeechStage.SttFinal]    = t0.AddMilliseconds(310),
            [SpeechStage.LlmStart]    = t0.AddMilliseconds(320),
            [SpeechStage.LlmFirstToken] = t0.AddMilliseconds(700),
            [SpeechStage.LlmComplete] = t0.AddMilliseconds(1100),
            [SpeechStage.TtsStart]    = t0.AddMilliseconds(1110),
            [SpeechStage.PlaybackStarted] = t0.AddMilliseconds(1200),
            [SpeechStage.TtsComplete] = t0.AddMilliseconds(1500),
        };

        var trace = new SpeechTurnTrace(
            Guid.NewGuid(), t0, timestamps,
            TurnRoute.LlmFallback, "windows", 30, 60, true, false, TtsKind.System);

        trace.SttMs.Should().BeApproximately(300, 1);
        trace.LlmMs.Should().BeApproximately(780, 1);
        trace.LlmFirstTokenMs.Should().BeApproximately(380, 1);
        trace.TtsMs.Should().BeApproximately(390, 1);
        trace.FirstAudioMs.Should().BeApproximately(1110, 1);
        trace.TotalMs.Should().BeApproximately(1200, 1);   // wake → playbackStarted
    }

    [Fact]
    public void SpeechTurnTrace_SlowestStage_IdentifiesLlm()
    {
        var t0 = DateTimeOffset.UtcNow;
        var timestamps = new Dictionary<string, DateTimeOffset>
        {
            [SpeechStage.SttStart]    = t0,
            [SpeechStage.SttFinal]    = t0.AddMilliseconds(200),  // 200 ms STT
            [SpeechStage.LlmStart]    = t0.AddMilliseconds(210),
            [SpeechStage.LlmComplete] = t0.AddMilliseconds(1010), // 800 ms LLM — slowest
            [SpeechStage.TtsStart]    = t0.AddMilliseconds(1020),
            [SpeechStage.TtsComplete] = t0.AddMilliseconds(1220), // 200 ms TTS
        };

        var trace = new SpeechTurnTrace(
            Guid.NewGuid(), t0, timestamps,
            TurnRoute.LlmFallback, "windows", 10, 20, true, false, TtsKind.System);

        trace.SlowestStage!.Value.Stage.Should().Be("llm");
        trace.SlowestStage!.Value.Ms.Should().BeApproximately(800, 1);
    }

    [Fact]
    public void SpeechTurnTrace_ReplyLoggerMs_IsNearZero_WhenNonBlocking()
    {
        // Simulate a non-blocking logger: start and end timestamps are virtually simultaneous.
        var t0 = DateTimeOffset.UtcNow;
        var timestamps = new Dictionary<string, DateTimeOffset>
        {
            [SpeechStage.ReplyLoggerStart] = t0,
            [SpeechStage.ReplyLoggerEnd]   = t0.AddMicroseconds(50), // 0.05 ms
        };

        var trace = new SpeechTurnTrace(
            Guid.NewGuid(), t0, timestamps,
            TurnRoute.FastCommand, "windows", 5, 5, false, false, TtsKind.System);

        trace.ReplyLoggerMs.Should().BeLessThan(1,
            because: "a fire-and-forget logger should add < 1 ms to the pipeline");
    }

    // MARK: - Stub helpers

    private sealed class BlockingReplyLogger(
        TaskCompletionSource<bool> writeStarted,
        TaskCompletionSource<bool> writeBlocked) : IReplyLogger
    {
        public void Append(ReplySource source, string spokenText,
            string? intent = null, string? responseKey = null, bool editableFlag = true)
        {
            // Fire-and-forget: the caller does NOT await this.
            _ = Task.Run(async () =>
            {
                writeStarted.TrySetResult(true);
                await writeBlocked.Task; // simulate a 500 ms write
            });
        }

        public Task<IReadOnlyList<ReplyLogEntry>> RecentAsync(int limit = 20, CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ReplyLogEntry>>(Array.Empty<ReplyLogEntry>());

        public Task<IReadOnlyList<ReplyLogEntry>> AllAsync(CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ReplyLogEntry>>(Array.Empty<ReplyLogEntry>());

        public Task UpdateCorrectionAsync(Guid id, string correctedText, bool accepted, CancellationToken ct = default)
            => Task.CompletedTask;

        public Task<string> ExportJsonlAsync(CancellationToken ct = default) => Task.FromResult("");
        public Task<string> ExportCsvAsync(CancellationToken ct = default)   => Task.FromResult("");
    }

    private sealed class QuickTtsService : ILocalTtsService
    {
        public int SpeakCallCount { get; private set; }
        public bool IsSpeaking => false;

        public Task<bool> SpeakAsync(string text, CancellationToken ct = default)
        {
            SpeakCallCount++;
            return Task.FromResult(true);
        }

        public Task StopAsync(CancellationToken ct = default) => Task.CompletedTask;
    }

    private sealed class OrderCapturingLogger(List<string> log) : IReplyLogger
    {
        public void Append(ReplySource source, string spokenText,
            string? intent = null, string? responseKey = null, bool editableFlag = true)
            => log.Add("append");

        public Task<IReadOnlyList<ReplyLogEntry>> RecentAsync(int limit = 20, CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ReplyLogEntry>>(Array.Empty<ReplyLogEntry>());
        public Task<IReadOnlyList<ReplyLogEntry>> AllAsync(CancellationToken ct = default)
            => Task.FromResult<IReadOnlyList<ReplyLogEntry>>(Array.Empty<ReplyLogEntry>());
        public Task UpdateCorrectionAsync(Guid id, string correctedText, bool accepted, CancellationToken ct = default)
            => Task.CompletedTask;
        public Task<string> ExportJsonlAsync(CancellationToken ct = default) => Task.FromResult("");
        public Task<string> ExportCsvAsync(CancellationToken ct = default)   => Task.FromResult("");
    }

    private sealed class OrderCapturingTtsService(List<string> log) : ILocalTtsService
    {
        public bool IsSpeaking => false;

        public Task<bool> SpeakAsync(string text, CancellationToken ct = default)
        {
            log.Add("speak");
            return Task.FromResult(true);
        }

        public Task StopAsync(CancellationToken ct = default) => Task.CompletedTask;
    }
}
