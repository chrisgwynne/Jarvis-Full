using Jarvis.Core.Sidecar;

namespace Jarvis.Settings;

/// <summary>
/// Thread-safe 20-turn ring buffer for speech pipeline latency.
/// Registered as a singleton in DI; Mark() and CompleteTurn() are non-blocking.
/// </summary>
public sealed class SpeechLatencyTracker : ISpeechLatencyTracker
{
    private sealed class Builder
    {
        public Guid TurnId { get; } = Guid.NewGuid();
        public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
        public Dictionary<string, DateTimeOffset> Timestamps { get; } = new();
        public TurnRoute Route { get; set; } = TurnRoute.Unknown;
        public int TranscriptLength { get; set; }
        public int ReplyLength { get; set; }
        public bool LlmUsed { get; set; }
        public bool ToolUsed { get; set; }
        public TtsKind TtsKind { get; set; } = TtsKind.System;

        public void Mark(string stage) => Timestamps[stage] = DateTimeOffset.UtcNow;

        public SpeechTurnTrace Build() => new(
            TurnId, StartedAt, new Dictionary<string, DateTimeOffset>(Timestamps),
            Route, "windows", TranscriptLength, ReplyLength, LlmUsed, ToolUsed, TtsKind);
    }

    private readonly object _sync = new();
    private Builder? _current;
    private readonly List<SpeechTurnTrace> _traces = new();
    private const int Cap = 20;

    public Guid BeginTurn()
    {
        var b = new Builder();
        lock (_sync) { _current = b; }
        return b.TurnId;
    }

    public void Mark(string stage)
    {
        lock (_sync) { _current?.Mark(stage); }
    }

    public void SetRoute(TurnRoute route)           { lock (_sync) { if (_current is not null) _current.Route = route; } }
    public void SetTranscriptLength(int chars)      { lock (_sync) { if (_current is not null) _current.TranscriptLength = chars; } }
    public void SetReplyLength(int chars)           { lock (_sync) { if (_current is not null) _current.ReplyLength = chars; } }
    public void SetLlmUsed(bool used)               { lock (_sync) { if (_current is not null) _current.LlmUsed = used; } }
    public void SetToolUsed(bool used)              { lock (_sync) { if (_current is not null) _current.ToolUsed = used; } }
    public void SetTtsKind(TtsKind kind)            { lock (_sync) { if (_current is not null) _current.TtsKind = kind; } }

    public void CompleteTurn()
    {
        Builder? b;
        lock (_sync)
        {
            b = _current;
            _current = null;
        }
        if (b is null) return;
        var trace = b.Build();
        lock (_sync)
        {
            _traces.Add(trace);
            if (_traces.Count > Cap) _traces.RemoveAt(0);
        }
    }

    public IReadOnlyList<SpeechTurnTrace> RecentTraces(int limit = 20)
    {
        lock (_sync)
        {
            var result = _traces.AsEnumerable().Reverse().Take(limit).ToList();
            return result;
        }
    }

    public double? AverageTotalMs()
    {
        var vals = RecentTraces().Select(t => t.TotalMs).OfType<double>().ToList();
        return vals.Count == 0 ? null : vals.Average();
    }

    public double? P50() => Percentile(0.50);
    public double? P95() => Percentile(0.95);

    private double? Percentile(double p)
    {
        var vals = RecentTraces()
            .Select(t => t.TotalMs)
            .OfType<double>()
            .OrderBy(x => x)
            .ToList();
        if (vals.Count == 0) return null;
        var idx = Math.Clamp((int)(vals.Count * p), 0, vals.Count - 1);
        return vals[idx];
    }

    public IReadOnlyDictionary<TurnRoute, int> RouteBreakdown()
    {
        return RecentTraces()
            .GroupBy(t => t.Route)
            .ToDictionary(g => g.Key, g => g.Count());
    }
}
