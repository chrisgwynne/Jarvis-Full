namespace Jarvis.Core.Perception;

public sealed record OcrWord(string Text, double Confidence, OcrRect Bounds);
public sealed record OcrLine(string Text, IReadOnlyList<OcrWord> Words);

public readonly record struct OcrRect(double X, double Y, double Width, double Height);

public sealed record OcrResult(
    DateTimeOffset CapturedAt,
    string Text,
    string Language,
    IReadOnlyList<OcrLine> Lines,
    TimeSpan Duration,
    double AverageConfidence)
{
    public static OcrResult Empty(TimeSpan duration) =>
        new(DateTimeOffset.UtcNow, string.Empty, "und", Array.Empty<OcrLine>(), duration, 0);
}

public interface IOcrService
{
    bool IsAvailable { get; }
    Task<OcrResult> RecognizeAsync(byte[] pngBytes, CancellationToken cancellationToken = default);
}

public interface IOcrPostProcessor
{
    string Clean(string rawText);
}
