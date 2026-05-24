using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Windows.Media.SpeechSynthesis;

namespace Jarvis.App.Sidecar;

/// <summary>
/// Lease-gated TTS using Windows.Media.SpeechSynthesis to produce a PCM WAV stream,
/// then <see cref="System.Media.SoundPlayer"/> for playback. <see cref="StopAsync"/>
/// interrupts immediately (the platform-side Stop() returns within a frame).
///
/// Lease semantics — Windows must hold the lease before <see cref="SpeakAsync"/> will
/// emit anything. The lease is requested but never self-granted; <see cref="RequestLocalLease"/>
/// only forwards a request to Mac, so this method returns false until Mac responds.
/// </summary>
public sealed class WinRtTtsService : ILocalTtsService, IAsyncDisposable
{
    private readonly ITtsLeaseCoordinator _lease;
    private readonly Func<SidecarSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly AudioDiagnostics? _audioDiag;
    private readonly object _gate = new();

    private SpeechSynthesizer? _synth;
    private System.Media.SoundPlayer? _player;
    private CancellationTokenSource? _activeCts;
    private bool _speaking;

    /// <summary>Optional hook for the perception-side interruption coordinator —
    /// called whenever playback starts/stops so it can flip the echo suppressor.</summary>
    public Action<bool>? PlaybackChanged { get; set; }

    public bool IsSpeaking { get { lock (_gate) return _speaking; } }

    public WinRtTtsService(
        ITtsLeaseCoordinator lease,
        Func<SidecarSettings> settings,
        IDiagnostics? diagnostics = null,
        AudioDiagnostics? audioDiag = null)
    {
        _lease = lease;
        _settings = settings;
        _diagnostics = diagnostics;
        _audioDiag = audioDiag;
    }

    public async Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        if (!_settings().LocalTtsEnabled) return false;
        if (!_lease.RequestLocalLease("local TTS")) return false;
        if (_lease.Current.Owner != SpeakerOwner.Windows) return false;

        var startedAt = DateTimeOffset.UtcNow;
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lock (_gate)
        {
            _activeCts?.Cancel();
            _activeCts = cts;
            _speaking = true;
        }
        _lease.NotifyLocalSpeaking(true);
        PlaybackChanged?.Invoke(true);

        try
        {
            _synth ??= new SpeechSynthesizer();
            using var synthStream = await _synth.SynthesizeTextToStreamAsync(text)
                .AsTask(cts.Token).ConfigureAwait(false);

            // SpeechSynthesisStream is WinRT IRandomAccessStream. Copy to a managed MemoryStream
            // so SoundPlayer (which expects a System.IO.Stream) can consume it.
            var size = (int)synthStream.Size;
            var buffer = new Windows.Storage.Streams.Buffer((uint)size);
            await synthStream.ReadAsync(buffer, (uint)size, Windows.Storage.Streams.InputStreamOptions.None)
                .AsTask(cts.Token).ConfigureAwait(false);
            var bytes = buffer.ToArray();

            var ms = new MemoryStream(bytes);
            var player = new System.Media.SoundPlayer(ms);
            lock (_gate) _player = player;

            if (_audioDiag is not null)
            {
                var elapsed = (long)(DateTimeOffset.UtcNow - startedAt).TotalMilliseconds;
                Interlocked.Add(ref _audioDiag.TtsStartLatencyTotalMs, elapsed);
                Interlocked.Increment(ref _audioDiag.TtsStartLatencyCount);
            }

            player.Play(); // non-blocking
            // Approximate duration: average English speech ~16 chars/sec at normal rate; use
            // a 50 ms-per-char ceiling with a 200 ms floor. SoundPlayer doesn't expose duration,
            // so we wait for cancellation or the timer.
            var approxMs = Math.Min(60_000, Math.Max(200, text.Length * 60));
            try { await Task.Delay(approxMs, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { /* interruption */ }

            return !cts.IsCancellationRequested;
        }
        catch (OperationCanceledException) { return false; }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "tts", "speak failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return false;
        }
        finally
        {
            try { lock (_gate) _player?.Stop(); } catch { }
            lock (_gate) { _player = null; _speaking = false; if (_activeCts == cts) _activeCts = null; }
            PlaybackChanged?.Invoke(false);
            _lease.NotifyLocalSpeaking(false);
            cts.Dispose();
        }
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        CancellationTokenSource? cts;
        System.Media.SoundPlayer? player;
        lock (_gate) { cts = _activeCts; player = _player; }
        try { cts?.Cancel(); } catch { }
        try { player?.Stop(); } catch { }
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        lock (_gate) { _synth?.Dispose(); _synth = null; }
    }
}
