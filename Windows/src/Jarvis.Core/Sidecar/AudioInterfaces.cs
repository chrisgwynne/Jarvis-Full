namespace Jarvis.Core.Sidecar;

public sealed record AudioDevice(string Id, string Name, bool IsDefault);

/// <summary>Enumeration + hot-swap notifications for microphones and speakers.</summary>
public interface IAudioDeviceCoordinator
{
    IReadOnlyList<AudioDevice> Microphones { get; }
    IReadOnlyList<AudioDevice> Speakers { get; }
    event EventHandler? DevicesChanged;
    Task RefreshAsync(CancellationToken cancellationToken = default);
}

public sealed record TranscriptEvent(
    string SessionId,
    string Text,
    double Confidence,
    bool IsFinal,
    DateTimeOffset At);

/// <summary>Streaming microphone capture + STT. Real impls use Windows.Media.SpeechRecognition;
/// the P6 ship has a stub for the architecture to be exercised without a working mic.</summary>
public interface IMicrophoneCapture : IAsyncDisposable
{
    bool IsCapturing { get; }
    event EventHandler<TranscriptEvent>? Transcript;

    Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);

    /// <summary>Test seam — push a transcript through as if STT had produced it.</summary>
    void Inject(TranscriptEvent ev);
}

/// <summary>Local Text-to-Speech. Lease-aware; refuses to speak unless Windows holds
/// the speaker lease (via <see cref="ITtsLeaseCoordinator"/>).</summary>
public interface ILocalTtsService
{
    bool IsSpeaking { get; }
    /// <summary>Speak the supplied text. Returns false immediately if the lease isn't
    /// held or local TTS is disabled in settings.</summary>
    Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
}
