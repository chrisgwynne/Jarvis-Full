using System.Runtime.CompilerServices;
using Jarvis.Core.Conversation;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// P5 placeholder. Streams a deterministic "no model configured" reply, optionally
/// including a peek at the context so the user can see what would have been sent.
/// A real provider plug-in (OpenAI / MiniMax / Ollama) replaces this in DI by
/// implementing <see cref="ILlmClient"/>.
/// </summary>
public sealed class EchoLlmClient : ILlmClient
{
    public bool IsConfigured => false;

    public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        // Stream in small chunks so the UI can demonstrate the streaming pipeline.
        var pieces = new[]
        {
            "_(No language model is configured. The local router handles obvious requests; ",
            "anything else falls through to here.)_\n\n",
            "I'd send this to the model:\n\n",
            $"> {Trim(request.UserMessage)}\n\n",
            "with this context:\n```\n",
            ContextSummary(request.Context),
            "\n```"
        };
        foreach (var piece in pieces)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await Task.Delay(40, cancellationToken).ConfigureAwait(false);
            yield return piece;
        }
    }

    public static string ContextSummary(ConversationContext c)
    {
        var lines = new List<string>(8);
        if (!string.IsNullOrEmpty(c.ForegroundApp))
            lines.Add($"foreground: {c.ForegroundApp} — {c.ForegroundWindowTitle ?? ""}");
        lines.Add($"workflow: {c.Workflow}");
        if (c.Browser is { Url: { Length: > 0 } } b)
            lines.Add($"browser: {b.Title} @ {b.Url}");
        if (c.Ide is { HasContent: true } ide)
            lines.Add($"ide: {ide.Editor} · {ide.ActiveFile ?? "?"}");
        if (!string.IsNullOrEmpty(c.SelectedText))
            lines.Add($"selection [{c.SelectedTextType}]: {Trim(c.SelectedText!, 120)}");
        if (!string.IsNullOrEmpty(c.ClipboardSummary))
            lines.Add($"clipboard [{c.ClipboardType}]: {Trim(c.ClipboardSummary!, 80)}");
        if (c.LastHighlighted is not null)
            lines.Add($"last highlight: {c.LastHighlighted.Label} ({c.LastHighlighted.Source})");
        lines.Add($"snapshot hash: {c.SnapshotHash}");
        return string.Join('\n', lines);
    }

    private static string Trim(string s, int max = 200) =>
        s.Length <= max ? s : s[..max] + "…";
}
