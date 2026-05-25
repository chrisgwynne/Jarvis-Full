using System.Text.Json.Serialization;

namespace Jarvis.Core.Sidecar;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TurnRoute { FastCommand, LlmFallback, LlmWithTool, DirectCommand, Unknown }

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TtsKind { Local, Cloud, System }

/// <summary>
/// Full timing and metadata snapshot for one voice-to-voice pipeline turn.
/// Stored in a 20-turn ring buffer by <see cref="ISpeechLatencyTracker"/>.
/// </summary>
public sealed record SpeechTurnTrace(
    Guid TurnId,
    DateTimeOffset StartedAt,
    IReadOnlyDictionary<string, DateTimeOffset> Timestamps,
    TurnRoute Route,
    string Device,
    int TranscriptLength,
    int ReplyLength,
    bool LlmUsed,
    bool ToolUsed,
    TtsKind TtsKind)
{
    public double? TotalMs =>
        Delta("wake_detect", "playback_started")
        ?? Delta("wake_detect", "tts_complete");

    public double? FirstAudioMs => Delta("wake_detect", "tts_start");
    public double? SttMs        => Delta("stt_start",   "stt_final");
    public double? IntentMs     => Delta("stt_final",   "intent_route");
    public double? LlmMs        => Delta("llm_start",   "llm_complete");
    public double? LlmFirstTokenMs => Delta("llm_start", "llm_first_token");
    public double? TtsMs        => Delta("tts_start",   "tts_complete");
    public double? ToolMs       => Delta("tool_start",  "tool_end");
    public double? ReplyLoggerMs => Delta("reply_logger_start", "reply_logger_end");

    private double? Delta(string from, string to)
    {
        if (!Timestamps.TryGetValue(from, out var a) || !Timestamps.TryGetValue(to, out var b))
            return null;
        return (b - a).TotalMilliseconds;
    }

    public (string Stage, double Ms)? SlowestStage
    {
        get
        {
            var candidates = new[]
            {
                ("stt",          SttMs),
                ("intent",       IntentMs),
                ("llm",          LlmMs),
                ("tool",         ToolMs),
                ("tts",          TtsMs),
                ("replyLogger",  ReplyLoggerMs),
            };
            (string, double)? best = null;
            foreach (var (stage, ms) in candidates)
            {
                if (ms is not null && (best is null || ms > best.Value.Item2))
                    best = (stage, ms.Value);
            }
            return best;
        }
    }
}
