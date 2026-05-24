using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Filters mic transcripts that look like the assistant hearing itself. Heuristics
/// (deliberately conservative — false positives just mean Mac sees a duplicate that
/// gets dropped at the brain; false negatives let the assistant talk to itself):
///
///   1. Any speaker active → suppress everything.
///   2. Within the post-speech cooldown window (700 ms) → suppress.
///   3. The transcript is a fuzzy match (≥ similarity threshold) of recently spoken text
///      → suppress as echo.
///   4. Privacy mode → suppress everything.
/// </summary>
public sealed class EchoSuppressionCoordinator : IEchoSuppressionCoordinator
{
    private static readonly TimeSpan PostSpeechCooldown = TimeSpan.FromMilliseconds(700);
    private const int RecentTextWindow = 6;

    private readonly Func<SidecarSettings> _settings;
    private readonly object _gate = new();
    private readonly LinkedList<string> _recentSpoken = new();
    private readonly LinkedList<(string Norm, DateTimeOffset At)> _recentSent = new();
    private DateTimeOffset _speakerStoppedAt = DateTimeOffset.MinValue;
    private bool _speakerActive;
    private bool _privacy;
    private bool _playbackActive;

    public EchoSuppressionCoordinator(Func<SidecarSettings> settings)
    {
        _settings = settings;
        // Sync privacy mode from persisted settings so it survives app restarts.
        // Without this, _privacy would default to false even when settings.json has
        // PrivacyMode=true, causing transcripts to leak until the user re-toggles mute.
        _privacy = settings().PrivacyMode;
    }

    public void NotifySpeaker(SpeakerOwner owner, string text, bool starting)
    {
        lock (_gate)
        {
            if (starting)
            {
                _speakerActive = true;
                if (!string.IsNullOrWhiteSpace(text))
                {
                    _recentSpoken.AddLast(Normalize(text));
                    while (_recentSpoken.Count > RecentTextWindow) _recentSpoken.RemoveFirst();
                }
            }
            else
            {
                _speakerActive = false;
                _speakerStoppedAt = DateTimeOffset.UtcNow;
            }
        }
    }

    public void SetPrivacyMode(bool privacy) { lock (_gate) _privacy = privacy; }

    public void NotifyPlaybackActive(bool active)
    {
        lock (_gate)
        {
            _playbackActive = active;
            if (!active) _speakerStoppedAt = DateTimeOffset.UtcNow;
        }
    }

    /// <summary>While playback is rendering, wake detection should be paused or made
    /// significantly less sensitive so the assistant doesn't trigger itself.</summary>
    public bool ShouldSuppressWakeWord()
    {
        lock (_gate)
        {
            if (_privacy) return true;
            if (_playbackActive) return true;
            if (_speakerActive) return true;
            if (DateTimeOffset.UtcNow - _speakerStoppedAt < PostSpeechCooldown) return true;
            return false;
        }
    }

    public bool IsLikelyEcho(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        lock (_gate)
        {
            // Use a lower similarity threshold for echo detection — we want to catch
            // partial matches even when STT mangles the first/last words.
            var threshold = Math.Min(0.5, Math.Clamp(_settings().EchoSuppressionStrength, 0.0, 1.0));
            if (threshold <= 0) return false;
            var norm = Normalize(text);
            foreach (var spoken in _recentSpoken)
            {
                if (Similarity(spoken, norm) >= threshold) return true;
                // Contains-check for short partials of long utterances.
                if (norm.Length >= 4 && spoken.Contains(norm)) return true;
            }
            return false;
        }
    }

    public SuppressionReason ShouldSuppress(string transcript)
    {
        if (string.IsNullOrWhiteSpace(transcript)) return SuppressionReason.None;
        lock (_gate)
        {
            if (_privacy) return SuppressionReason.PrivacyMode;
            if (_playbackActive) return SuppressionReason.PlaybackActive;
            if (_speakerActive) return SuppressionReason.SpeakerActive;
            if (DateTimeOffset.UtcNow - _speakerStoppedAt < PostSpeechCooldown) return SuppressionReason.PostSpeechCooldown;

            var threshold = Math.Clamp(_settings().EchoSuppressionStrength, 0.0, 1.0);
            var norm = Normalize(transcript);

            // Duplicate dedup: same normalised transcript inside a 2s window is a duplicate
            // (STT engines sometimes emit a "final" twice or repeat after a partial).
            var now = DateTimeOffset.UtcNow;
            while (_recentSent.Count > 0 && now - _recentSent.First!.Value.At > TimeSpan.FromSeconds(2))
                _recentSent.RemoveFirst();
            foreach (var (sent, _) in _recentSent)
                if (sent == norm) return SuppressionReason.Duplicate;

            if (threshold > 0)
            {
                foreach (var spoken in _recentSpoken)
                {
                    if (Similarity(spoken, norm) >= threshold)
                        return SuppressionReason.EchoSimilarity;
                }
            }

            _recentSent.AddLast((norm, now));
            while (_recentSent.Count > RecentTextWindow) _recentSent.RemoveFirst();
            return SuppressionReason.None;
        }
    }

    internal static string Normalize(string s)
    {
        // Lowercase + strip everything that isn't a letter/digit/space.
        var sb = new System.Text.StringBuilder(s.Length);
        foreach (var c in s.ToLowerInvariant())
            if (char.IsLetterOrDigit(c) || c == ' ') sb.Append(c);
        return System.Text.RegularExpressions.Regex.Replace(sb.ToString().Trim(), @"\s+", " ");
    }

    /// <summary>Jaccard similarity on the word sets. Cheap; robust enough for short
    /// utterances. Returns 1.0 for identical token sets, 0 for disjoint.</summary>
    internal static double Similarity(string a, string b)
    {
        if (a == b) return 1.0;
        if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return 0;
        var setA = new HashSet<string>(a.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        var setB = new HashSet<string>(b.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        if (setA.Count == 0 || setB.Count == 0) return 0;
        var intersection = setA.Intersect(setB).Count();
        var union = setA.Union(setB).Count();
        return (double)intersection / union;
    }
}
