namespace Jarvis.Core.Perception;

public sealed record ClipboardEntry(
    DateTimeOffset CapturedAt,
    SemanticContentType ContentType,
    string? Text,
    int? ImageWidth,
    int? ImageHeight,
    string? SourceApp,
    string ContentHash)
{
    public bool IsText => Text is { Length: > 0 };
    public bool IsImage => ImageWidth is > 0 && ImageHeight is > 0;
}

public interface IClipboardMonitor : IAsyncDisposable
{
    /// <summary>Most recent entry, or null if nothing observed yet.</summary>
    ClipboardEntry? Latest { get; }

    /// <summary>Bounded recent history (newest first).</summary>
    IReadOnlyList<ClipboardEntry> History { get; }

    event EventHandler<ClipboardEntry>? Changed;

    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
}

public interface ISemanticContentClassifier
{
    SemanticContentType Classify(string? text);
}
