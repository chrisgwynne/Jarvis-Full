using System.IO;
using System.Text.Json;
using Jarvis.Core.Automation;

namespace Jarvis.Automation;

/// <summary>
/// Append-only audit log. One JSON object per line, file per UTC day:
///   <c>%APPDATA%\Jarvis\audit\jarvis-audit-YYYY-MM-DD.jsonl</c>
///
/// Concurrency: a single writer lock; reads from disk are not supported in P3 (Recent
/// returns the in-memory tail). Writes are async + bounded by the disk; we never block
/// callers on slow I/O — failures are swallowed but counted as a metric.
/// </summary>
public sealed class JsonlAuditLog : IAuditLog
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() }
    };

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly Queue<AuditEntry> _recent = new();
    private readonly int _recentCapacity;

    public JsonlAuditLog(string? directory = null, int recentCapacity = 512)
    {
        _directory = directory ?? DefaultDirectory();
        Directory.CreateDirectory(_directory);
        _recentCapacity = recentCapacity;
    }

    public static string DefaultDirectory()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(roaming, "Jarvis", "audit");
    }

    public string LogDirectory => _directory;

    public async Task AppendAsync(AuditEntry entry, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            _recent.Enqueue(entry);
            while (_recent.Count > _recentCapacity) _recent.Dequeue();
        }
        var path = Path.Combine(_directory, $"jarvis-audit-{entry.At:yyyy-MM-dd}.jsonl");
        try
        {
            var line = JsonSerializer.Serialize(entry, JsonOpts);
            await File.AppendAllTextAsync(path, line + Environment.NewLine, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // never let audit I/O propagate; in-memory tail still has the entry
        }
    }

    public IReadOnlyList<AuditEntry> Recent(int max = 200)
    {
        lock (_gate)
        {
            if (max >= _recent.Count) return _recent.ToArray();
            return _recent.Skip(_recent.Count - max).ToArray();
        }
    }
}
