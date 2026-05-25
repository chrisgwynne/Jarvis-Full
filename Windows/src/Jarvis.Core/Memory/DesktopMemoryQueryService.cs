namespace Jarvis.Core.Memory;

public sealed record DesktopMemoryAnswer(
    string Query,
    string NaturalLanguageAnswer,
    object? StructuredData,     // typed data for programmatic use
    DateTimeOffset AnsweredAt);

public interface IDesktopMemoryQueryService
{
    Task<DesktopMemoryAnswer> AnswerAsync(string query, CancellationToken ct = default);
}
