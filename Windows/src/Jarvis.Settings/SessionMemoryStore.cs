using System.Text.Json;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Memory;

namespace Jarvis.Settings;

/// <summary>
/// Persists <see cref="WorkSession"/> records as a JSONL file under
/// %APPDATA%\Jarvis\sessions.jsonl. Thread-safe via a <see cref="SemaphoreSlim"/>.
/// File is capped at 512 KB; when exceeded on write the oldest 20 % of lines are trimmed.
/// </summary>
public sealed class SessionMemoryStore : ISessionMemoryStore
{
    private const long MaxFileSizeBytes = 512 * 1024;
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Jarvis",
        "sessions.jsonl");

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly IDiagnostics? _diagnostics;

    public SessionMemoryStore(IDiagnostics? diagnostics = null)
    {
        _diagnostics = diagnostics;
    }

    public async Task<IReadOnlyList<WorkSession>> GetTodayAsync()
    {
        var today = DateTimeOffset.UtcNow.Date;
        var all = await ReadAllAsync().ConfigureAwait(false);
        return all.Where(s => s.StartedAt.Date == today).ToList();
    }

    public async Task<IReadOnlyList<WorkSession>> GetRecentAsync(int days = 7)
    {
        var cutoff = DateTimeOffset.UtcNow.AddDays(-days);
        var all = await ReadAllAsync().ConfigureAwait(false);
        return all.Where(s => s.StartedAt >= cutoff).ToList();
    }

    public async Task SaveSessionAsync(WorkSession session)
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var line = JsonSerializer.Serialize(session, JsonOpts);
            await File.AppendAllTextAsync(FilePath, line + "\n").ConfigureAwait(false);
            _diagnostics?.Record(DiagnosticLevel.Info, "memory", "memory.session.saved",
                new Dictionary<string, object?> { ["bytes"] = System.Text.Encoding.UTF8.GetByteCount(line) });
            await TrimIfOversizedAsync().ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task ClearAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (File.Exists(FilePath))
                File.Delete(FilePath);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task<long> GetStoreSizeAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!File.Exists(FilePath)) return 0;
            return new FileInfo(FilePath).Length;
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task<List<WorkSession>> ReadAllAsync()
    {
        await _lock.WaitAsync().ConfigureAwait(false);
        try
        {
            return ReadAllUnlocked();
        }
        finally
        {
            _lock.Release();
        }
    }

    private List<WorkSession> ReadAllUnlocked()
    {
        if (!File.Exists(FilePath)) return new List<WorkSession>();
        var lines = File.ReadAllLines(FilePath);
        var result = new List<WorkSession>(lines.Length);
        foreach (var line in lines)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                var session = JsonSerializer.Deserialize<WorkSession>(line, JsonOpts);
                if (session is not null)
                    result.Add(session);
            }
            catch
            {
                // Skip malformed lines
            }
        }
        return result;
    }

    // Must be called under _lock.
    private async Task TrimIfOversizedAsync()
    {
        if (!File.Exists(FilePath)) return;
        var size = new FileInfo(FilePath).Length;
        if (size <= MaxFileSizeBytes) return;

        var lines = await File.ReadAllLinesAsync(FilePath).ConfigureAwait(false);
        var nonEmpty = lines.Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
        if (nonEmpty.Length == 0) return;

        // Trim oldest 20 %
        var trimCount = Math.Max(1, nonEmpty.Length / 5);
        var kept = nonEmpty.Skip(trimCount).ToArray();
        await File.WriteAllLinesAsync(FilePath, kept).ConfigureAwait(false);
    }
}
