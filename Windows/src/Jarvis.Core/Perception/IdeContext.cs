namespace Jarvis.Core.Perception;

/// <summary>
/// Compact view of the user's active IDE/editor. Populated by heuristics that don't
/// require IDE extensions (window-title parsing + .git walk). When a future VS Code or
/// JetBrains companion lands, the same shape is filled from richer signals.
/// </summary>
public sealed record IdeContext(
    DateTimeOffset CapturedAt,
    string? Editor,
    string? ActiveFile,
    string? ProjectRoot,
    string? RepoRoot,
    string? Branch,
    bool ProviderSupported)
{
    public static IdeContext Empty => new(DateTimeOffset.UtcNow, null, null, null, null, null, false);
    public bool HasContent => Editor is not null || ActiveFile is not null || RepoRoot is not null;
}

public interface IIdeContextProvider
{
    /// <summary>Cheap snapshot read. Implementations cache derived state (repo root, branch)
    /// and refresh only when the foreground window changes.</summary>
    IdeContext TryReadContext();
}
