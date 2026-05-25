using System.Security.Cryptography;
using System.Text;
using Jarvis.Core.Awareness;
using Jarvis.Core.Context;
using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Context;

/// <summary>
/// Produces a <see cref="WindowsContextSnapshot"/> from a <see cref="SemanticSnapshot"/>,
/// a <see cref="PrivacySafeTimeline"/>, focus metrics, and presence mode. Computes a SHA1
/// hash of the fields that matter for downstream context consumers so they can skip work
/// when nothing changed.
/// </summary>
public sealed class WindowsContextSnapshotBuilder : IWindowsContextSnapshotBuilder
{
    private const int MaxRecentProcessNames = 5;

    public WindowsContextSnapshot Build(
        SemanticSnapshot semantic,
        PrivacySafeTimeline timeline,
        FocusMetrics focus,
        PresenceMode presenceMode)
    {
        var recentProcessNames = timeline.Entries
            .Select(e => e.ProcessName)
            .Where(n => !string.IsNullOrEmpty(n))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .TakeLast(MaxRecentProcessNames)
            .ToArray();

        var hash = ComputeHash(semantic, timeline, recentProcessNames, focus, presenceMode);

        return new WindowsContextSnapshot(
            CapturedAt: DateTimeOffset.UtcNow,
            Semantic: semantic,
            Timeline: timeline,
            RecentProcessNames: recentProcessNames,
            Focus: focus,
            PresenceMode: presenceMode,
            Hash: hash);
    }

    private static string ComputeHash(
        SemanticSnapshot semantic,
        PrivacySafeTimeline timeline,
        string[] recentProcessNames,
        FocusMetrics focus,
        PresenceMode presenceMode)
    {
        var key = string.Join('|',
            semantic.Hash,
            string.Join(',', recentProcessNames),
            timeline.ToCompactSummary(),
            focus.FocusDuration.TotalMinutes.ToString("F0"),
            presenceMode.ToString());
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(key));
        return Convert.ToHexString(bytes);
    }
}
