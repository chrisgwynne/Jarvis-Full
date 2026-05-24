using Jarvis.Core.Sidecar;

namespace Jarvis.App.Sidecar;

/// <summary>
/// P6 stub. Real impl in P6.5 enumerates devices via Windows.Media.Devices.MediaDevice
/// (WinRT) and hooks DefaultAudio[Capture|Render]DeviceChanged. For now we publish a
/// single virtual "default" device so the rest of the architecture can be exercised.
/// </summary>
public sealed class StubAudioDeviceCoordinator : IAudioDeviceCoordinator
{
    private static readonly AudioDevice DefaultMic = new("default-mic", "Default microphone", IsDefault: true);
    private static readonly AudioDevice DefaultSpeaker = new("default-speaker", "Default speaker", IsDefault: true);

    public IReadOnlyList<AudioDevice> Microphones { get; } = new[] { DefaultMic };
    public IReadOnlyList<AudioDevice> Speakers { get; } = new[] { DefaultSpeaker };
    public event EventHandler? DevicesChanged { add { } remove { } }
    public Task RefreshAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
}
