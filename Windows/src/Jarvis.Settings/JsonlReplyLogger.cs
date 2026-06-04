using System.Text;
using System.Text.Json;
using Jarvis.Core.Conversation;
using Jarvis.Core.Logging;

namespace Jarvis.Settings;

/// <summary>
/// JSONL-backed reply logger. File: %APPDATA%\Jarvis\reply_log.jsonl.
/// Bounded to 4 MB / 2000 entries; rotates by dropping the oldest half.
/// All I/O runs on a dedicated single-threaded channel via SemaphoreSlim.
/// </summary>
public sealed class JsonlReplyLogger : IReplyLogger
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        // camelCase enum values keep the export consistent with the camelCase property
        // naming above (e.g. "command", "tool", "proactive"). Reads stay case-insensitive.
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly int _maxBytes = 4 * 1024 * 1024;
    private readonly int _maxEntries = 2_000;
    private List<ReplyLogEntry>? _cache;
    // WIN-9 (#32): redact PII/secrets from the spoken text before it is
    // persisted. Null → no redaction (used by some tests).
    private readonly IRedactor? _redactor;

    public JsonlReplyLogger() : this(null) { }

    public JsonlReplyLogger(string? filePath, IRedactor? redactor = null)
    {
        _redactor = redactor;
        if (filePath is not null)
        {
            _filePath = filePath;
        }
        else
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Jarvis");
            Directory.CreateDirectory(dir);
            _filePath = Path.Combine(dir, "reply_log.jsonl");
        }
    }

    // MARK: Append

    public void Append(
        ReplySource source,
        string spokenText,
        string? intent = null,
        string? responseKey = null,
        bool editableFlag = true)
    {
        if (string.IsNullOrWhiteSpace(spokenText)) return;
        // WIN-9 (#32): redact before persisting so the on-disk log never
        // carries raw secrets/PII from the spoken text.
        var loggedText = _redactor?.Redact(spokenText).Cleaned ?? spokenText;
        var entry = new ReplyLogEntry(
            Id: Guid.NewGuid(),
            Timestamp: DateTimeOffset.UtcNow,
            Source: source,
            Intent: intent,
            ResponseKey: responseKey,
            SpokenText: loggedText,
            Device: "windows",
            EditableFlag: editableFlag);
        _ = Task.Run(() => WriteAsync(entry));
    }

    private async Task WriteAsync(ReplyLogEntry entry)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var line = JsonSerializer.Serialize(entry, _opts) + "\n";
            await File.AppendAllTextAsync(_filePath, line, Encoding.UTF8).ConfigureAwait(false);
            _cache?.Add(entry);
            if (_cache?.Count > _maxEntries)
                _cache.RemoveRange(0, _cache.Count - _maxEntries);
            await RotateIfNeededAsync().ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private async Task RotateIfNeededAsync()
    {
        var info = new FileInfo(_filePath);
        if (!info.Exists || info.Length <= _maxBytes) return;
        var lines = (await File.ReadAllLinesAsync(_filePath).ConfigureAwait(false))
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .ToArray();
        var keep = lines.Skip(lines.Length / 2).ToArray();
        await File.WriteAllTextAsync(_filePath, string.Join('\n', keep) + "\n", Encoding.UTF8).ConfigureAwait(false);
        _cache = null;
    }

    // MARK: Read

    public async Task<IReadOnlyList<ReplyLogEntry>> RecentAsync(int limit = 100, CancellationToken cancellationToken = default)
    {
        var all = await LoadCacheAsync(cancellationToken).ConfigureAwait(false);
        return all.TakeLast(limit).ToList();
    }

    public async Task<IReadOnlyList<ReplyLogEntry>> AllAsync(CancellationToken cancellationToken = default)
        => await LoadCacheAsync(cancellationToken).ConfigureAwait(false);

    private async Task<List<ReplyLogEntry>> LoadCacheAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_cache is not null) return _cache;
            _cache = new List<ReplyLogEntry>();
            if (!File.Exists(_filePath)) return _cache;
            foreach (var line in await File.ReadAllLinesAsync(_filePath, cancellationToken).ConfigureAwait(false))
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    var e = JsonSerializer.Deserialize<ReplyLogEntry>(line, _opts);
                    if (e is not null) _cache.Add(e);
                }
                catch { /* skip corrupt line */ }
            }
            if (_cache.Count > _maxEntries)
                _cache = _cache.TakeLast(_maxEntries).ToList();
            return _cache;
        }
        finally { _gate.Release(); }
    }

    // MARK: Edit

    public async Task UpdateCorrectionAsync(Guid id, string correctedText, bool accepted, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var cache = await LoadCacheInternalAsync(cancellationToken).ConfigureAwait(false);
            var idx = cache.FindIndex(e => e.Id == id);
            if (idx < 0) return;
            cache[idx] = cache[idx] with { CorrectedText = correctedText, Accepted = accepted };
            await RewriteFileAsync(cache).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private async Task<List<ReplyLogEntry>> LoadCacheInternalAsync(CancellationToken cancellationToken)
    {
        if (_cache is not null) return _cache;
        _cache = new List<ReplyLogEntry>();
        if (!File.Exists(_filePath)) return _cache;
        foreach (var line in await File.ReadAllLinesAsync(_filePath, cancellationToken).ConfigureAwait(false))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                var e = JsonSerializer.Deserialize<ReplyLogEntry>(line, _opts);
                if (e is not null) _cache.Add(e);
            }
            catch { }
        }
        return _cache;
    }

    private async Task RewriteFileAsync(List<ReplyLogEntry> entries)
    {
        var lines = entries.Select(e => JsonSerializer.Serialize(e, _opts));
        await File.WriteAllTextAsync(_filePath, string.Join('\n', lines) + "\n", Encoding.UTF8).ConfigureAwait(false);
    }

    // MARK: Export

    public async Task<string> ExportJsonlAsync(CancellationToken cancellationToken = default)
    {
        var entries = await AllAsync(cancellationToken).ConfigureAwait(false);
        return string.Join('\n', entries.Select(e => JsonSerializer.Serialize(e, _opts)));
    }

    public async Task<string> ExportCsvAsync(CancellationToken cancellationToken = default)
    {
        var entries = await AllAsync(cancellationToken).ConfigureAwait(false);
        var sb = new StringBuilder();
        sb.AppendLine("timestamp,source,intent,responseKey,spokenText,correctedText,accepted,device,editableFlag");
        foreach (var e in entries)
        {
            sb.AppendLine(string.Join(',',
                e.Timestamp.ToString("O"),
                e.Source.ToString().ToLowerInvariant(),
                e.Intent ?? "",
                e.ResponseKey ?? "",
                CsvEscape(e.SpokenText),
                e.CorrectedText is not null ? CsvEscape(e.CorrectedText) : "",
                e.Accepted?.ToString().ToLower() ?? "",
                e.Device,
                e.EditableFlag.ToString().ToLower()));
        }
        return sb.ToString();
    }

    private static string CsvEscape(string s) => $"\"{s.Replace("\"", "\"\"")}\"";
}
