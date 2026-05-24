using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;
using Windows.Devices.Enumeration;
using Windows.Media.Devices;

namespace Jarvis.App.Sidecar;

/// <summary>
/// WinRT-backed device coordinator. Enumerates microphones / speakers via
/// <see cref="DeviceInformation"/> + <see cref="MediaDevice"/>, and watches for
/// add/remove/update with two <see cref="DeviceWatcher"/>s. Default-device changes
/// (Bluetooth disconnect → fall back to internal speaker, etc.) are surfaced through
/// <see cref="DevicesChanged"/>.
/// </summary>
public sealed class WinRtAudioDeviceCoordinator : IAudioDeviceCoordinator, IAsyncDisposable
{
    private readonly IDiagnostics? _diagnostics;
    private readonly AudioDiagnostics? _audioDiag;
    private readonly object _gate = new();
    private List<AudioDevice> _mics = new();
    private List<AudioDevice> _speakers = new();
    private DeviceWatcher? _micWatcher;
    private DeviceWatcher? _speakerWatcher;

    public event EventHandler? DevicesChanged;

    public IReadOnlyList<AudioDevice> Microphones { get { lock (_gate) return _mics.ToArray(); } }
    public IReadOnlyList<AudioDevice> Speakers { get { lock (_gate) return _speakers.ToArray(); } }

    public WinRtAudioDeviceCoordinator(IDiagnostics? diagnostics = null, AudioDiagnostics? audioDiag = null)
    {
        _diagnostics = diagnostics;
        _audioDiag = audioDiag;
    }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var defaultMicId = TryGetDefault(() => MediaDevice.GetDefaultAudioCaptureId(AudioDeviceRole.Default));
            var defaultSpeakerId = TryGetDefault(() => MediaDevice.GetDefaultAudioRenderId(AudioDeviceRole.Default));

            var mics = await DeviceInformation.FindAllAsync(MediaDevice.GetAudioCaptureSelector())
                .AsTask(cancellationToken).ConfigureAwait(false);
            var speakers = await DeviceInformation.FindAllAsync(MediaDevice.GetAudioRenderSelector())
                .AsTask(cancellationToken).ConfigureAwait(false);

            lock (_gate)
            {
                _mics = mics.Select(d => new AudioDevice(d.Id, d.Name, d.Id == defaultMicId)).ToList();
                _speakers = speakers.Select(d => new AudioDevice(d.Id, d.Name, d.Id == defaultSpeakerId)).ToList();
            }
            EnsureWatchers();
            DevicesChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "audio.devices", "refresh failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    private static string? TryGetDefault(Func<string> getter)
    {
        try { return getter(); } catch { return null; }
    }

    private void EnsureWatchers()
    {
        if (_micWatcher is null)
        {
            _micWatcher = DeviceInformation.CreateWatcher(MediaDevice.GetAudioCaptureSelector());
            HookWatcher(_micWatcher, "mic");
            _micWatcher.Start();
        }
        if (_speakerWatcher is null)
        {
            _speakerWatcher = DeviceInformation.CreateWatcher(MediaDevice.GetAudioRenderSelector());
            HookWatcher(_speakerWatcher, "speaker");
            _speakerWatcher.Start();
        }
    }

    private void HookWatcher(DeviceWatcher watcher, string kind)
    {
        watcher.Added   += (_, _) => OnDeviceChange(kind);
        watcher.Removed += (_, _) => OnDeviceChange(kind);
        watcher.Updated += (_, _) => OnDeviceChange(kind);
    }

    private void OnDeviceChange(string kind)
    {
        if (_audioDiag is not null) Interlocked.Increment(ref _audioDiag.DeviceChanges);
        _diagnostics?.Record(DiagnosticLevel.Info, "audio.devices", $"{kind} change");
        // Coalesce: a single refresh re-reads everything.
        _ = RefreshAsync();
    }

    public async ValueTask DisposeAsync()
    {
        try { _micWatcher?.Stop(); _speakerWatcher?.Stop(); } catch { }
        await Task.CompletedTask;
    }
}
