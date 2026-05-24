using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;

namespace Jarvis.App.Sidecar;

/// <summary>
/// Lease-gated wrapper around the eventual real TTS engine. In P6 the speak path is a
/// no-op: it requests a lease, refuses if it can't get one, and otherwise marks
/// the lease as in-use. P6.5 plugs in the real System.Speech (or WinRT
/// Windows.Media.SpeechSynthesis) backend.
/// </summary>
public sealed class LeaseGatedTtsService : ILocalTtsService
{
    private readonly ITtsLeaseCoordinator _lease;
    private readonly Func<SidecarSettings> _settings;
    private bool _speaking;

    public LeaseGatedTtsService(ITtsLeaseCoordinator lease, Func<SidecarSettings> settings)
    {
        _lease = lease;
        _settings = settings;
    }

    public bool IsSpeaking => _speaking;

    public async Task<bool> SpeakAsync(string text, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        if (!_settings().LocalTtsEnabled) return false;
        if (!_lease.RequestLocalLease("local TTS")) return false;
        if (_lease.Current.Owner != SpeakerOwner.Windows) return false;

        _speaking = true;
        _lease.NotifyLocalSpeaking(true);
        try
        {
            // P6.5: actual TTS engine. P6 fakes it with a length-proportional delay so
            // the pebble's Speaking state has visible duration.
            await Task.Delay(Math.Min(3000, 30 * text.Length), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _speaking = false;
            _lease.NotifyLocalSpeaking(false);
        }
        return true;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        _speaking = false;
        _lease.NotifyLocalSpeaking(false);
        return Task.CompletedTask;
    }
}
