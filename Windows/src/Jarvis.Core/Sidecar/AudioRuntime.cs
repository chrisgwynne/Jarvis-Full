namespace Jarvis.Core.Sidecar;

/// <summary>
/// Pluggable wake-word seam. Default impl uses Windows.Media.SpeechRecognition with a
/// list-constraint grammar (local, no cloud). An ONNX/openWakeWord impl can plug in
/// here without touching the rest of the pipeline.
/// </summary>
public interface IWakeWordDetector : IAsyncDisposable
{
    /// <summary>Whether the detector is currently listening for the wake word.</summary>
    bool IsListening { get; }

    /// <summary>Fired whenever the configured wake phrase is detected with confidence
    /// above the configured threshold.</summary>
    event EventHandler<WakeDetection>? Detected;

    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);

    /// <summary>Lower sensitivity (e.g. during TTS playback) to avoid wake storms.</summary>
    void SetSuppressed(bool suppressed);
}

public sealed record WakeDetection(string Phrase, double Confidence, DateTimeOffset At);

/// <summary>
/// Pluggable streaming STT seam. Real impl on Windows uses
/// Windows.Media.SpeechRecognition's continuous-recognition session. Tests inject
/// a fake by raising the events directly.
/// </summary>
public interface ISpeechRecognitionProvider : IAsyncDisposable
{
    bool IsRecognizing { get; }

    /// <summary>Interim partial transcripts. May fire many times before a final.</summary>
    event EventHandler<TranscriptEvent>? Partial;

    /// <summary>Stable final transcript for a single utterance.</summary>
    event EventHandler<TranscriptEvent>? Final;

    /// <summary>Started/stopped lifecycle hook for diagnostics.</summary>
    event EventHandler<bool>? RecognizingChanged;

    Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Fans partial / final transcripts out to the bridge as <c>transcript.partial</c> /
/// <c>transcript.final</c> frames. Applies echo suppression and dedup so the assistant
/// doesn't hear itself, and tags interruption events when speech arrives during TTS.
/// </summary>
public interface IPartialTranscriptCoordinator
{
    int PartialsSent { get; }
    int FinalsSent { get; }
    int SuppressedPartials { get; }
    int SuppressedFinals { get; }
    int Interruptions { get; }

    /// <summary>Subscribes to a recognition provider and starts forwarding.</summary>
    void Attach(ISpeechRecognitionProvider provider);

    /// <summary>Stops forwarding. Idempotent.</summary>
    void Detach();
}

/// <summary>
/// Watches local mic activity while TTS is speaking. If a partial transcript arrives
/// while Windows holds the TTS lease, playback is stopped immediately and an
/// <c>interruption</c> marker is published.
/// </summary>
public interface IPlaybackInterruptionCoordinator
{
    int Interruptions { get; }

    /// <summary>Raised the moment an interruption is detected — before the
    /// <c>speaker.silent</c> bridge frame is sent. Renderer subscribes to flash the
    /// pebble in-paint instead of waiting for the next state push.</summary>
    event EventHandler? Interrupted;

    /// <summary>Hook the recognition stream + local TTS lifecycle together.</summary>
    void Attach(ISpeechRecognitionProvider recognition, ILocalTtsService tts);
    void Detach();
}

/// <summary>Aggregate audio runtime metrics. Updated lock-free; readers may see stale
/// values but counters never decrement.</summary>
public sealed class AudioDiagnostics
{
    public int WakeDetections;
    public int FalseWakes;
    public int Partials;
    public int Finals;
    public int DroppedFrames;
    public int DeviceChanges;
    public int SuppressedFromPlayback;
    public int SuppressedFromCooldown;
    public int SuppressedFromSimilarity;
    public int DuplicateTranscripts;
    public int Interruptions;
    public long FirstPartialLatencyTotalMs;
    public int FirstPartialLatencyCount;
    public long FinalLatencyTotalMs;
    public int FinalLatencyCount;
    public long TtsStartLatencyTotalMs;
    public int TtsStartLatencyCount;

    public double FirstPartialAvgMs => FirstPartialLatencyCount == 0 ? 0
        : (double)FirstPartialLatencyTotalMs / FirstPartialLatencyCount;
    public double FinalAvgMs => FinalLatencyCount == 0 ? 0
        : (double)FinalLatencyTotalMs / FinalLatencyCount;
    public double TtsStartAvgMs => TtsStartLatencyCount == 0 ? 0
        : (double)TtsStartLatencyTotalMs / TtsStartLatencyCount;
}
