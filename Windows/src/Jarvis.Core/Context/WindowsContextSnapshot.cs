using Jarvis.Core.Focus;
using Jarvis.Core.Presence;
using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Context;

/// <summary>
/// Enriched desktop context snapshot that combines the semantic snapshot with the
/// privacy-safe app usage timeline. Carries a stable SHA1 hash of the meaningful
/// fields so consumers can cheaply detect when something relevant changed.
/// </summary>
public sealed record WindowsContextSnapshot(
    DateTimeOffset CapturedAt,
    SemanticSnapshot Semantic,
    PrivacySafeTimeline Timeline,
    string[] RecentProcessNames,
    FocusMetrics Focus,
    PresenceMode PresenceMode,
    string Hash);

/// <summary>
/// Produces a <see cref="WindowsContextSnapshot"/> from the latest semantic snapshot
/// and app usage history.
/// </summary>
public interface IWindowsContextSnapshotBuilder
{
    WindowsContextSnapshot Build(
        SemanticSnapshot semantic,
        PrivacySafeTimeline timeline,
        FocusMetrics focus,
        PresenceMode presenceMode);
}
