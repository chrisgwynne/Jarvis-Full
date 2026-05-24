using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Watches incoming partial-transcript events while local TTS is playing. The first
/// partial that arrives during playback stops the speaker immediately and emits an
/// interruption marker frame so the Mac can replan. Always lease-safe: stopping the
/// speaker also releases the Windows lease via <see cref="ITtsLeaseCoordinator.NotifyLocalSpeaking"/>
/// which the TTS service is expected to call from its finally block.
/// </summary>
public sealed class PlaybackInterruptionCoordinator : IPlaybackInterruptionCoordinator, IDisposable
{
    private readonly IMacBridgeCoordinator _bridge;
    private readonly IEchoSuppressionCoordinator _echo;
    private readonly ITtsLeaseCoordinator _lease;
    private readonly AudioDiagnostics _diag;
    private readonly IDiagnostics? _diagnostics;
    private readonly PartialTranscriptCoordinator? _partialCoord;

    private ISpeechRecognitionProvider? _recognition;
    private ILocalTtsService? _tts;
    private int _interruptions;
    private DateTimeOffset _playbackStartedAt;

    public int Interruptions => _interruptions;
    public event EventHandler? Interrupted;

    public PlaybackInterruptionCoordinator(
        IMacBridgeCoordinator bridge,
        IEchoSuppressionCoordinator echo,
        ITtsLeaseCoordinator lease,
        AudioDiagnostics diag,
        PartialTranscriptCoordinator? partialCoord = null,
        IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _echo = echo;
        _lease = lease;
        _diag = diag;
        _partialCoord = partialCoord;
        _diagnostics = diagnostics;
    }

    public void Attach(ISpeechRecognitionProvider recognition, ILocalTtsService tts)
    {
        Detach();
        _recognition = recognition;
        _tts = tts;
        recognition.Partial += OnPartial;
    }

    public void Detach()
    {
        if (_recognition is not null)
        {
            _recognition.Partial -= OnPartial;
            _recognition = null;
        }
        _tts = null;
    }

    /// <summary>Called by the TTS service whenever it transitions playing/not.</summary>
    public void NotifyPlaybackChanged(bool playing)
    {
        _echo.NotifyPlaybackActive(playing);
        if (playing)
        {
            _playbackStartedAt = DateTimeOffset.UtcNow;
            Interlocked.Add(ref _diag.TtsStartLatencyTotalMs, 0);
            Interlocked.Increment(ref _diag.TtsStartLatencyCount);
        }
    }

    private void OnPartial(object? sender, TranscriptEvent ev)
    {
        // Only interrupt if the user is *actually* speaking (non-empty partial) and
        // playback is rolling. Suppression checks are run inside the echo coordinator
        // so we don't interrupt for transcripts that are themselves echoes.
        if (_tts is null || !_tts.IsSpeaking) return;
        if (string.IsNullOrWhiteSpace(ev.Text)) return;
        // Don't interrupt for self-leak. Without AEC, the best we can do is similarity.
        if (_echo.IsLikelyEcho(ev.Text)) return;
        // Don't fire within the first 200ms of playback — STT can flush a stale partial
        // captured just before TTS started.
        if (DateTimeOffset.UtcNow - _playbackStartedAt < TimeSpan.FromMilliseconds(200)) return;

        // Stop the speaker first — every millisecond counts perceptually.
        try { _ = _tts.StopAsync(); } catch { /* shutting down */ }
        Interlocked.Increment(ref _interruptions);
        Interlocked.Increment(ref _diag.Interruptions);
        _partialCoord?.MarkInterruption();
        _diagnostics?.Record(DiagnosticLevel.Info, "sidecar.tts", "playback interrupted by user speech");
        try { Interrupted?.Invoke(this, EventArgs.Empty); } catch { /* don't let renderer subscriber break interruption */ }

        // Tell Mac so it can replan.
        _ = _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.SpeakerSilent,
            Source = "windows",
            Reason = "interrupted",
            At = DateTimeOffset.UtcNow
        });

        // The TTS service itself owns NotifyLocalSpeaking(false); calling it here would
        // double-emit speaker.silent. We only emit the interruption-tagged frame above
        // and let the TTS finally block handle lease cleanup.
    }

    public void Dispose() => Detach();
}
