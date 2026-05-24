using System.IO;
using System.Runtime.CompilerServices;

namespace Jarvis.Perception.Conversation.Providers;

/// <summary>
/// Minimal Server-Sent-Events parser. Yields one "event" per blank-line-terminated
/// block, returning the concatenated <c>data:</c> lines. Honours cancellation between
/// reads. We do not care about <c>event:</c> / <c>id:</c> fields — every supported
/// provider puts its payload in <c>data:</c>.
/// </summary>
internal static class SseLineReader
{
    public static async IAsyncEnumerable<string> ReadAsync(Stream stream,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(stream);
        var current = new System.Text.StringBuilder();
        while (!reader.EndOfStream)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null) break;
            if (line.Length == 0)
            {
                if (current.Length > 0)
                {
                    yield return current.ToString();
                    current.Clear();
                }
                continue;
            }
            if (line.StartsWith("data:", StringComparison.Ordinal))
            {
                var data = line.Length > 5 && line[5] == ' ' ? line[6..] : line[5..];
                if (current.Length > 0) current.Append('\n');
                current.Append(data);
            }
            // Ignore comments / event / id lines.
        }
        if (current.Length > 0) yield return current.ToString();
    }
}
