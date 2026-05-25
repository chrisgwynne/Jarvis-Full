namespace Jarvis.Core.Logging;

/// <summary>
/// Central log for every spoken reply Jarvis produces on Windows.
/// All appends are fire-and-forget; reads are async.
/// </summary>
public interface IReplyLogger
{
    void Append(
        ReplySource source,
        string spokenText,
        string? intent = null,
        string? responseKey = null,
        bool editableFlag = true);

    Task<IReadOnlyList<ReplyLogEntry>> RecentAsync(int limit = 100, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ReplyLogEntry>> AllAsync(CancellationToken cancellationToken = default);

    Task UpdateCorrectionAsync(Guid id, string correctedText, bool accepted, CancellationToken cancellationToken = default);

    Task<string> ExportJsonlAsync(CancellationToken cancellationToken = default);
    Task<string> ExportCsvAsync(CancellationToken cancellationToken = default);
}
