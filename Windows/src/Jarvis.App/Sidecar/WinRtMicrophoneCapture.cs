using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;

namespace Jarvis.App.Sidecar;

/// <summary>
/// Composes the wake detector + streaming STT into a single <see cref="IMicrophoneCapture"/>.
///
/// When wake-word is enabled (default), STT is dormant until the wake word fires; on
/// detection STT runs for an active window (default 10 s, refreshed on each new partial)
/// and then returns to wake-only mode.
///
/// When wake-word is disabled, STT runs continuously — push-to-talk callers gate via
/// <see cref="StartAsync"/> / <see cref="StopAsync"/>.
///
/// The <see cref="Inject"/> seam still works in either mode so tests + the chat panel can
/// drive transcripts without a real microphone.
/// </summary>
public sealed class WinRtMicrophoneCapture : IMicrophoneCapture
{
    private static readonly TimeSpan ActiveWindow = TimeSpan.FromSeconds(10);

    private readonly IWakeWordDetector _wake;
    private readonly ISpeechRecognitionProvider _stt;
    private readonly Func<SidecarSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();

    private bool _capturing;
    private string? _activeMicId;
    private DateTimeOffset _lastActivityAt;
    private CancellationTokenSource? _activeWindowCts;

    public event EventHandler<TranscriptEvent>? Transcript;

    public bool IsCapturing { get { lock (_gate) return _capturing; } }

    public WinRtMicrophoneCapture(
        IWakeWordDetector wake,
        ISpeechRecognitionProvider stt,
        Func<SidecarSettings> settings,
        IDiagnostics? diagnostics = null)
    {
        _wake = wake;
        _stt = stt;
        _settings = settings;
        _diagnostics = diagnostics;

        _wake.Detected += OnWakeDetected;
        _stt.Partial += OnSttPartial;
        _stt.Final += OnSttFinal;
    }

    public async Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_capturing) return;
            _capturing = true;
            _activeMicId = microphoneId;
        }
        try
        {
            if (_settings().WakeWordEnabled)
            {
                await _wake.StartAsync(cancellationToken).ConfigureAwait(false);
            }
            else
            {
                await _stt.StartAsync(microphoneId, cancellationToken).ConfigureAwait(false);
            }
            _diagnostics?.Record(DiagnosticLevel.Info, "mic", "capture started",
                new Dictionary<string, object?>
                {
                    ["mic"] = microphoneId,
                    ["wake"] = _settings().WakeWordEnabled
                });
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "mic", "start failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate) { if (!_capturing) return; _capturing = false; }
        try { _activeWindowCts?.Cancel(); } catch { }
        try { await _stt.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
        try { await _wake.StopAsync(cancellationToken).ConfigureAwait(false); } catch { }
    }

    public void Inject(TranscriptEvent ev) => Transcript?.Invoke(this, ev);

    private async void OnWakeDetected(object? sender, WakeDetection ev)
    {
        _diagnostics?.Record(DiagnosticLevel.Info, "wake", "detected",
            new Dictionary<string, object?>
            {
                // Privacy: never log the raw recognized phrase — record length + short hash only.
                ["phraseLen"] = DiagnosticsRedaction.Length(ev.Phrase),
                ["phraseHash"] = DiagnosticsRedaction.Hash(ev.Phrase),
                ["confidence"] = ev.Confidence
            });
        // Open the active window: pause wake, start STT.
        try
        {
            _wake.SetSuppressed(true);
            await _stt.StartAsync(_activeMicId).ConfigureAwait(false);
            lock (_gate)
            {
                _activeWindowCts?.Cancel();
                _activeWindowCts = new CancellationTokenSource();
                _lastActivityAt = DateTimeOffset.UtcNow;
            }
            _ = WatchActiveWindowAsync(_activeWindowCts!.Token);
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "wake", "active-window open failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    private async Task WatchActiveWindowAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(500, token).ConfigureAwait(false);
                lock (_gate)
                {
                    if (DateTimeOffset.UtcNow - _lastActivityAt > ActiveWindow) break;
                }
            }
        }
        catch (OperationCanceledException) { return; }
        // Window closed: stop STT, re-arm wake.
        try { await _stt.StopAsync().ConfigureAwait(false); } catch { }
        _wake.SetSuppressed(false);
    }

    private void OnSttPartial(object? sender, TranscriptEvent ev)
    {
        lock (_gate) _lastActivityAt = DateTimeOffset.UtcNow;
        Transcript?.Invoke(this, ev);
    }

    private void OnSttFinal(object? sender, TranscriptEvent ev)
    {
        lock (_gate) _lastActivityAt = DateTimeOffset.UtcNow;
        Transcript?.Invoke(this, ev);
    }

    public async ValueTask DisposeAsync()
    {
        _wake.Detected -= OnWakeDetected;
        _stt.Partial -= OnSttPartial;
        _stt.Final -= OnSttFinal;
        try { await StopAsync().ConfigureAwait(false); } catch { }
        if (_wake is IAsyncDisposable wd) await wd.DisposeAsync().ConfigureAwait(false);
        if (_stt is IAsyncDisposable sd) await sd.DisposeAsync().ConfigureAwait(false);
    }
}
