namespace Jarvis.Core.Sidecar;

/// <summary>
/// Records per-turn speech pipeline timings.
/// All methods are thread-safe and non-blocking.
/// </summary>
public interface ISpeechLatencyTracker
{
    /// <summary>Start a new turn. Returns the new turn ID.</summary>
    Guid BeginTurn();

    /// <summary>Record a timestamp for the given pipeline stage key.</summary>
    void Mark(string stage);

    void SetRoute(TurnRoute route);
    void SetTranscriptLength(int chars);
    void SetReplyLength(int chars);
    void SetLlmUsed(bool used);
    void SetToolUsed(bool used);
    void SetTtsKind(TtsKind kind);

    /// <summary>Finalise the current turn and add it to the ring buffer.</summary>
    void CompleteTurn();

    IReadOnlyList<SpeechTurnTrace> RecentTraces(int limit = 20);
    double? AverageTotalMs();
    double? P50();
    double? P95();
    IReadOnlyDictionary<TurnRoute, int> RouteBreakdown();
}

/// <summary>Well-known stage keys used throughout the Windows pipeline.</summary>
public static class SpeechStage
{
    public const string WakeDetect               = "wake_detect";
    public const string SttStart                 = "stt_start";
    public const string SttFirstPartial          = "stt_first_partial";
    public const string SttFinal                 = "stt_final";
    public const string VadFinal                 = "vad_final";
    public const string TranscriptCorrectionStart = "transcript_correction_start";
    public const string TranscriptCorrectionEnd   = "transcript_correction_end";
    public const string IntentRoute              = "intent_route";
    public const string CommandMatchStart        = "command_match_start";
    public const string CommandMatchEnd          = "command_match_end";
    public const string ToolStart                = "tool_start";
    public const string ToolEnd                  = "tool_end";
    public const string LlmStart                 = "llm_start";
    public const string LlmFirstToken            = "llm_first_token";
    public const string LlmComplete              = "llm_complete";
    public const string ResponseCompositionStart = "response_composition_start";
    public const string ResponseCompositionEnd   = "response_composition_end";
    public const string ReplyLoggerStart         = "reply_logger_start";
    public const string ReplyLoggerEnd           = "reply_logger_end";
    public const string TtsStart                 = "tts_start";
    public const string FirstAudioBuffer         = "first_audio_buffer";
    public const string PlaybackStarted          = "playback_started";
    public const string TtsComplete              = "tts_complete";
}
