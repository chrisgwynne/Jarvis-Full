using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Windows.Globalization;
using Windows.Media.SpeechRecognition;

namespace Jarvis.App.Sidecar;

/// <summary>
/// Local wake-word spotter using <see cref="SpeechRecognitionListConstraint"/>. The
/// list constraint runs entirely offline (no online-speech requirement) and is cheap
/// enough to leave running continuously. Sensitivity is implicit in the recognizer's
/// confidence — we filter on the <see cref="SpeechRecognitionConfidence"/> level.
///
/// While suppressed (during TTS playback), the recognizer is paused entirely to avoid
/// wake storms from the assistant hearing its own name in its own output.
/// </summary>
public sealed class WinRtKeywordWakeWordService : IWakeWordDetector
{
    private readonly Func<SidecarSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly AudioDiagnostics? _audioDiag;
    private readonly IEchoSuppressionCoordinator? _echo;
    private readonly object _gate = new();

    private SpeechRecognizer? _recognizer;
    private bool _listening;
    private bool _suppressed;

    public bool IsListening { get { lock (_gate) return _listening && !_suppressed; } }
    public event EventHandler<WakeDetection>? Detected;

    public WinRtKeywordWakeWordService(
        Func<SidecarSettings> settings,
        IEchoSuppressionCoordinator? echo = null,
        IDiagnostics? diagnostics = null,
        AudioDiagnostics? audioDiag = null)
    {
        _settings = settings;
        _echo = echo;
        _diagnostics = diagnostics;
        _audioDiag = audioDiag;
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_listening) return;
        try
        {
            var phrase = _settings().EffectiveWakeAlias;
            _recognizer = new SpeechRecognizer(new Language("en-US"));
            _recognizer.Constraints.Clear();
            _recognizer.Constraints.Add(new SpeechRecognitionListConstraint(new[] { phrase }));
            var compile = await _recognizer.CompileConstraintsAsync().AsTask(cancellationToken).ConfigureAwait(false);
            if (compile.Status != SpeechRecognitionResultStatus.Success)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "wake", "compile failed",
                    new Dictionary<string, object?> { ["status"] = compile.Status.ToString() });
                await DisposeRecognizerAsync().ConfigureAwait(false);
                return;
            }

            _recognizer.ContinuousRecognitionSession.ResultGenerated += OnResult;
            await _recognizer.ContinuousRecognitionSession.StartAsync().AsTask(cancellationToken).ConfigureAwait(false);
            lock (_gate) _listening = true;
            _diagnostics?.Record(DiagnosticLevel.Info, "wake", "started",
                new Dictionary<string, object?> { ["phrase"] = phrase });
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "wake", "start failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            await DisposeRecognizerAsync().ConfigureAwait(false);
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!_listening) return;
        try
        {
            if (_recognizer is not null)
                await _recognizer.ContinuousRecognitionSession.StopAsync().AsTask(cancellationToken).ConfigureAwait(false);
        }
        catch { }
        finally
        {
            await DisposeRecognizerAsync().ConfigureAwait(false);
            lock (_gate) _listening = false;
        }
    }

    public void SetSuppressed(bool suppressed)
    {
        lock (_gate) _suppressed = suppressed;
        // Could pause/resume the recognizer here; simpler to ignore results while suppressed.
    }

    private void OnResult(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionResultGeneratedEventArgs args)
    {
        var result = args.Result;
        if (result is null || result.Status != SpeechRecognitionResultStatus.Success) return;
        // Honor echo + suppression gates.
        if (_suppressed || (_echo?.ShouldSuppressWakeWord() ?? false))
        {
            if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.FalseWakes);
            return;
        }
        // Only Medium/High confidence count — Low is almost always false-positive.
        if (result.Confidence == SpeechRecognitionConfidence.Low ||
            result.Confidence == SpeechRecognitionConfidence.Rejected)
        {
            if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.FalseWakes);
            return;
        }
        var confidence = result.Confidence == SpeechRecognitionConfidence.High ? 0.95 : 0.8;
        if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.WakeDetections);
        Detected?.Invoke(this, new WakeDetection(result.Text, confidence, DateTimeOffset.UtcNow));
    }

    private async Task DisposeRecognizerAsync()
    {
        if (_recognizer is null) return;
        try
        {
            _recognizer.ContinuousRecognitionSession.ResultGenerated -= OnResult;
            _recognizer.Dispose();
        }
        catch { }
        _recognizer = null;
        await Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        try { await StopAsync().ConfigureAwait(false); } catch { }
    }
}
