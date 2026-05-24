namespace Jarvis.Core.Sidecar;

public enum SuppressionReason
{
    /// <summary>Speaker (Mac or Windows) currently active.</summary>
    SpeakerActive,
    /// <summary>Post-speech cooldown window (~700 ms) — mic may still hear the tail.</summary>
    PostSpeechCooldown,
    /// <summary>Inbound transcript is similar to text the speaker recently uttered.</summary>
    EchoSimilarity,
    /// <summary>Privacy mode is on; suppress everything from this device's mic.</summary>
    PrivacyMode,
    /// <summary>Local or remote audio is actively rendering; mic is muted.</summary>
    PlaybackActive,
    /// <summary>Same transcript text was just delivered — duplicate.</summary>
    Duplicate,
    /// <summary>Not suppressed.</summary>
    None
}

/// <summary>
/// Decides whether an incoming transcript from the local mic should be forwarded to the
/// Mac, or suppressed because:
///   - a speaker (Mac or Windows) is currently active
///   - we're within the post-speech cooldown
///   - the transcript looks like an echo of what was just spoken
///   - privacy mode is on
/// </summary>
public interface IEchoSuppressionCoordinator
{
    /// <summary>Called by <see cref="ITtsLeaseCoordinator"/> when a speaker starts/stops.</summary>
    void NotifySpeaker(SpeakerOwner owner, string text, bool starting);

    /// <summary>Called by privacy toggle.</summary>
    void SetPrivacyMode(bool privacy);

    /// <summary>Called by the playback coordinator when local/remote audio playback starts
    /// or stops. Hard-suppresses transcripts while audio is rendering and gates the wake
    /// word, regardless of who owns the lease.</summary>
    void NotifyPlaybackActive(bool active);

    /// <summary>Wake-word detection should be paused / desensitised while playback is on.</summary>
    bool ShouldSuppressWakeWord();

    /// <summary>True iff the text is similar to something the assistant recently uttered
    /// — i.e. probably the mic picking up the speaker. Used to distinguish a real user
    /// interruption from leak-back during playback.</summary>
    bool IsLikelyEcho(string text);

    /// <summary>Should this transcript line be sent to Mac?</summary>
    SuppressionReason ShouldSuppress(string transcript);
}
