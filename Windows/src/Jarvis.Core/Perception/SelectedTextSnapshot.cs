namespace Jarvis.Core.Perception;

/// <summary>
/// One observation of the currently selected text in the foreground app.
/// Empty/null Text means "no selection" or "selection couldn't be read".
/// </summary>
public sealed record SelectedTextSnapshot(
    DateTimeOffset CapturedAt,
    string? Text,
    string? SourceApp,
    string? ElementName,
    string? AutomationId,
    string? ControlType,
    bool ProviderSupported)
{
    public static SelectedTextSnapshot Empty(string? sourceApp = null) =>
        new(DateTimeOffset.UtcNow, null, sourceApp, null, null, null, false);

    public bool HasSelection => !string.IsNullOrEmpty(Text);
}

public interface ISelectedTextProvider
{
    /// <summary>Tries to read selected text from the focused UIA element. Returns Empty when unavailable.</summary>
    SelectedTextSnapshot TryReadSelection();
}
