using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Windows.Globalization;
using Windows.Media.SpeechRecognition;

namespace Jarvis.App.Sidecar;

/// <summary>
/// Streaming STT via Windows.Media.SpeechRecognition. Uses
/// <see cref="SpeechRecognizer.ContinuousRecognitionSession"/> to deliver partial
/// <see cref="SpeechContinuousRecognitionSession.ResultGenerated"/> results and final
/// utterance commits as <see cref="ISpeechRecognitionProvider.Final"/> events.
///
/// Lifecycle:
///   StartAsync — compile constraints (dictation topic), open session, hook events.
///   StopAsync — gracefully stop the session; safe to start again.
///
/// Failure modes: mic permission denied, no language pack, online speech off. All are
/// logged via diagnostics; the service stays in a non-recognising state and the rest
/// of the pipeline keeps running (tests + push-to-talk + Mac fallback).
/// </summary>
public sealed class WinRtSpeechRecognitionService : ISpeechRecognitionProvider
{
    private readonly Func<SidecarSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly AudioDiagnostics? _audioDiag;
    private readonly object _gate = new();

    private SpeechRecognizer? _recognizer;
    private string _sessionId = Guid.NewGuid().ToString("N");
    private bool _recognizing;
    private DateTimeOffset _utteranceStartedAt;

    public bool IsRecognizing { get { lock (_gate) return _recognizing; } }

    public event EventHandler<TranscriptEvent>? Partial;
    public event EventHandler<TranscriptEvent>? Final;
    public event EventHandler<bool>? RecognizingChanged;

    public WinRtSpeechRecognitionService(
        Func<SidecarSettings> settings,
        IDiagnostics? diagnostics = null,
        AudioDiagnostics? audioDiag = null)
    {
        _settings = settings;
        _diagnostics = diagnostics;
        _audioDiag = audioDiag;
    }

    public async Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default)
    {
        if (IsRecognizing) return;
        try
        {
            var lang = new Language("en-US");
            _recognizer = new SpeechRecognizer(lang);
            _recognizer.Constraints.Clear();
            _recognizer.Constraints.Add(new SpeechRecognitionTopicConstraint(
                SpeechRecognitionScenario.Dictation, "dictation"));

            var compile = await _recognizer.CompileConstraintsAsync().AsTask(cancellationToken).ConfigureAwait(false);
            if (compile.Status != SpeechRecognitionResultStatus.Success)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "stt", "compile failed",
                    new Dictionary<string, object?> { ["status"] = compile.Status.ToString() });
                await DisposeRecognizerAsync().ConfigureAwait(false);
                return;
            }

            _recognizer.ContinuousRecognitionSession.ResultGenerated += OnFinalResult;
            _recognizer.HypothesisGenerated += OnHypothesis;
            _recognizer.ContinuousRecognitionSession.Completed += OnSessionCompleted;

            await _recognizer.ContinuousRecognitionSession.StartAsync().AsTask(cancellationToken).ConfigureAwait(false);
            _utteranceStartedAt = DateTimeOffset.UtcNow;
            SetRecognizing(true);
            _diagnostics?.Record(DiagnosticLevel.Info, "stt", "started");
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "stt", "start failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            await DisposeRecognizerAsync().ConfigureAwait(false);
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!IsRecognizing) return;
        try
        {
            if (_recognizer is not null)
                await _recognizer.ContinuousRecognitionSession.StopAsync().AsTask(cancellationToken).ConfigureAwait(false);
        }
        catch { /* ignore */ }
        finally
        {
            await DisposeRecognizerAsync().ConfigureAwait(false);
            SetRecognizing(false);
        }
    }

    private void OnHypothesis(SpeechRecognizer sender, SpeechRecognitionHypothesisGeneratedEventArgs args)
    {
        var text = args.Hypothesis?.Text;
        if (string.IsNullOrWhiteSpace(text)) return;
        if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.Partials);
        Partial?.Invoke(this, new TranscriptEvent(
            SessionId: _sessionId,
            Text: text,
            Confidence: 0.5, // hypotheses don't carry confidence; use a neutral value
            IsFinal: false,
            At: DateTimeOffset.UtcNow));
    }

    private void OnFinalResult(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionResultGeneratedEventArgs args)
    {
        var result = args.Result;
        if (result is null) return;
        if (result.Status != SpeechRecognitionResultStatus.Success) return;
        var text = result.Text;
        if (string.IsNullOrWhiteSpace(text)) return;
        if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.Finals);

        var confidence = result.Confidence switch
        {
            SpeechRecognitionConfidence.High => 0.95,
            SpeechRecognitionConfidence.Medium => 0.8,
            SpeechRecognitionConfidence.Low => 0.5,
            _ => 0.0
        };
        Final?.Invoke(this, new TranscriptEvent(
            SessionId: _sessionId,
            Text: text,
            Confidence: confidence,
            IsFinal: true,
            At: DateTimeOffset.UtcNow));
        _sessionId = Guid.NewGuid().ToString("N");
        _utteranceStartedAt = DateTimeOffset.UtcNow;
    }

    private void OnSessionCompleted(SpeechContinuousRecognitionSession sender, SpeechContinuousRecognitionCompletedEventArgs args)
    {
        SetRecognizing(false);
        // Auto-restart on benign stops if settings are still asking for STT.
        if (_settings().Enabled && _settings().WakeWordEnabled == false)
        {
            _ = StartAsync(null);
        }
    }

    private void SetRecognizing(bool value)
    {
        lock (_gate) _recognizing = value;
        RecognizingChanged?.Invoke(this, value);
    }

    private async Task DisposeRecognizerAsync()
    {
        if (_recognizer is null) return;
        try
        {
            _recognizer.ContinuousRecognitionSession.ResultGenerated -= OnFinalResult;
            _recognizer.HypothesisGenerated -= OnHypothesis;
            _recognizer.ContinuousRecognitionSession.Completed -= OnSessionCompleted;
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
