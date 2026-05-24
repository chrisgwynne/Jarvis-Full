namespace Jarvis.Core.Perception;

/// <summary>
/// Compact view of what the user is doing in their browser. Populated by an external
/// extension over a local IPC channel; in P2 we ship the host-side seam and a stub.
/// </summary>
public sealed record BrowserContextSnapshot(
    DateTimeOffset CapturedAt,
    string? Browser,
    string? Url,
    string? Domain,
    string? Title,
    string? SelectedText,
    string? FocusedElementRole,
    bool IsTextInputFocused)
{
    public static BrowserContextSnapshot Empty => new(
        DateTimeOffset.UtcNow, null, null, null, null, null, null, false);
}

public interface IBrowserContext
{
    BrowserContextSnapshot Current { get; }
    bool IsConnected { get; }
    event EventHandler<BrowserContextSnapshot>? Updated;
}
