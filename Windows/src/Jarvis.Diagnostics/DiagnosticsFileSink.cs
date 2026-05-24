using System.Collections.Concurrent;
using Jarvis.Core.Diagnostics;

namespace Jarvis.Diagnostics;

/// <summary>
/// Background async flush of diagnostic events to a dated log file.
/// Wraps an inner <see cref="IDiagnostics"/> so callers don't have to know about it.
/// </summary>
public sealed class DiagnosticsFileSink : IDiagnostics, IAsyncDisposable
{
    private readonly IDiagnostics _inner;
    private readonly string _directory;
    private readonly BlockingCollection<DiagnosticEntry> _queue = new(new ConcurrentQueue<DiagnosticEntry>());
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _writer;

    public DiagnosticsFileSink(IDiagnostics inner, string? directory = null)
    {
        _inner = inner;
        _directory = directory ?? DefaultDirectory();
        System.IO.Directory.CreateDirectory(_directory);
        _writer = Task.Run(RunAsync);
    }

    public static string DefaultDirectory()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(roaming, "Jarvis", "logs");
    }

    public string LogDirectory => _directory;

    public IReadOnlyDictionary<string, double> Metrics => _inner.Metrics;

    public void Record(DiagnosticLevel level, string category, string message, IReadOnlyDictionary<string, object?>? properties = null)
    {
        _inner.Record(level, category, message, properties);
        var entry = new DiagnosticEntry(DateTimeOffset.UtcNow, level, category, message, properties);
        try { _queue.Add(entry); } catch (InvalidOperationException) { /* shutting down */ }
    }

    public IReadOnlyList<DiagnosticEntry> Recent(int max = 200) => _inner.Recent(max);

    public void RecordMetric(string name, double value) => _inner.RecordMetric(name, value);

    private async Task RunAsync()
    {
        var token = _cts.Token;
        try
        {
            foreach (var entry in _queue.GetConsumingEnumerable(token))
            {
                var file = Path.Combine(_directory, $"jarvis-{entry.At:yyyy-MM-dd}.log");
                var line = Format(entry);
                try
                {
                    await File.AppendAllTextAsync(file, line + Environment.NewLine, token).ConfigureAwait(false);
                }
                catch
                {
                    // never let log I/O propagate
                }
            }
        }
        catch (OperationCanceledException) { /* shutting down */ }
    }

    private static string Format(DiagnosticEntry e)
    {
        var props = e.Properties is { Count: > 0 }
            ? " " + string.Join(' ', e.Properties.Select(kv => $"{kv.Key}={kv.Value}"))
            : string.Empty;
        return $"{e.At:O} {e.Level,-5} {e.Category} {e.Message}{props}";
    }

    public async ValueTask DisposeAsync()
    {
        _queue.CompleteAdding();
        _cts.Cancel();
        try { await _writer.ConfigureAwait(false); } catch { }
        _queue.Dispose();
        _cts.Dispose();
    }
}
