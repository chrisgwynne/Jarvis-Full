using Jarvis.Core.Sidecar;

namespace Jarvis.App.Sidecar;

/// <summary>
/// P6 stub. The architecture is complete; the real WinRT
/// <c>Windows.Media.SpeechRecognition.ContinuousRecognitionSession</c> wiring is the
/// only thing missing from P6.5. The <see cref="Inject"/> seam lets tests + the chat
/// panel still drive the pipeline end-to-end without a real microphone.
/// </summary>
public sealed class StubMicrophoneCapture : IMicrophoneCapture
{
    private bool _capturing;
    public bool IsCapturing => _capturing;
    public event EventHandler<TranscriptEvent>? Transcript;

    public Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default)
    {
        _capturing = true; return Task.CompletedTask;
    }
    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        _capturing = false; return Task.CompletedTask;
    }
    public void Inject(TranscriptEvent ev) => Transcript?.Invoke(this, ev);

    public ValueTask DisposeAsync()
    {
        _capturing = false;
        return ValueTask.CompletedTask;
    }
}
