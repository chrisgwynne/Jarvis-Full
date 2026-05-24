using System.Text.Json;
using Jarvis.Core.Diagnostics;

namespace Jarvis.Diagnostics;

public static class DiagnosticsExporter
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    public static async Task ExportJsonAsync(IDiagnostics diagnostics, string path, CancellationToken cancellationToken = default)
    {
        var payload = new
        {
            exportedAt = DateTimeOffset.UtcNow,
            metrics = diagnostics.Metrics,
            entries = diagnostics.Recent(2048).Select(e => new
            {
                at = e.At,
                level = e.Level.ToString(),
                category = e.Category,
                message = e.Message,
                properties = e.Properties
            })
        };
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await using var fs = File.Create(path);
        await JsonSerializer.SerializeAsync(fs, payload, JsonOpts, cancellationToken).ConfigureAwait(false);
    }
}
