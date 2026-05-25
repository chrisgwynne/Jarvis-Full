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
    string Hash);

/// <summary>
/// Produces a <see cref="WindowsContextSnapshot"/> from the latest semantic snapshot
/// and app usage history.
/// </summary>
public interface IWindowsContextSnapshotBuilder
{
    WindowsContextSnapshot Build(SemanticSnapshot semantic, PrivacySafeTimeline timeline);
}
