using System.Text;
using Jarvis.Core.Conversation;

namespace Jarvis.Perception.Conversation;

public sealed record ConversationExportOptions(
    string? ProviderLine,
    /// <summary>When true, includes per-turn snapshot hashes and routing info.
    /// Never includes raw redacted context bodies.</summary>
    bool IncludeDebugMetadata);

public static class ConversationExporter
{
    public static string ToMarkdown(IReadOnlyList<ChatMessage> history, IReadOnlyList<ConversationDiagnostics> diagnostics,
        ConversationExportOptions options)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# Jarvis chat — exported {DateTimeOffset.UtcNow:yyyy-MM-dd HH:mm} UTC");
        if (!string.IsNullOrEmpty(options.ProviderLine))
            sb.AppendLine($"_Provider: {options.ProviderLine}_");
        sb.AppendLine();

        var diagIdx = 0;
        for (var i = 0; i < history.Count; i++)
        {
            var msg = history[i];
            ConversationDiagnostics? diag = null;
            if (msg.Role == ChatRole.Assistant && diagIdx < diagnostics.Count)
                diag = diagnostics[diagIdx++];

            switch (msg.Role)
            {
                case ChatRole.User:
                    sb.AppendLine($"## You · {msg.At:HH:mm:ss}");
                    sb.AppendLine();
                    sb.AppendLine($"> {EscapeMarkdownQuote(msg.Content)}");
                    sb.AppendLine();
                    break;

                case ChatRole.Assistant:
                    var routeLabel = msg.RoutedIntent is null or "Unknown" ? "LLM" : msg.RoutedIntent;
                    sb.AppendLine($"## Jarvis · {msg.At:HH:mm:ss} · {routeLabel}");
                    if (options.IncludeDebugMetadata && diag is not null)
                    {
                        sb.AppendLine();
                        sb.Append("_snapshot=").Append(diag.SnapshotHash);
                        if (diag.LlmUsed) sb.Append($" · provider={diag.ProviderType}/{diag.Model}");
                        if (diag.FirstTokenMs is not null) sb.Append($" · first-token={diag.FirstTokenMs:F0}ms");
                        sb.Append($" · total={diag.TotalMs:F0}ms");
                        if (diag.Redaction is { Replacements: > 0 } r)
                            sb.Append($" · redactions={r.Replacements}");
                        if (diag.CancelReason is not null) sb.Append($" · cancelled={diag.CancelReason}");
                        sb.AppendLine("_");
                    }
                    sb.AppendLine();
                    sb.AppendLine(msg.Content);
                    sb.AppendLine();
                    break;

                case ChatRole.System:
                    sb.AppendLine($"_(system · {msg.At:HH:mm:ss})_");
                    sb.AppendLine();
                    sb.AppendLine(msg.Content);
                    sb.AppendLine();
                    break;
            }
        }
        return sb.ToString();
    }

    private static string EscapeMarkdownQuote(string s) =>
        s.Replace("\r", "").Replace("\n", "\n> ");
}
