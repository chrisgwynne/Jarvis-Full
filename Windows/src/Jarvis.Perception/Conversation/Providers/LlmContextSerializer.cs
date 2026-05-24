using System.Text;
using Jarvis.Core.Conversation;

namespace Jarvis.Perception.Conversation.Providers;

/// <summary>
/// One canonical "system message" body shared by every real provider. The local router
/// already handled the obvious intents — by the time we get here we want the LLM to
/// know what the user is looking at, but in plain readable text, not JSON.
/// </summary>
internal static class LlmContextSerializer
{
    public static string BuildSystemMessage(string basePrompt, ConversationContext context)
    {
        var sb = new StringBuilder();
        sb.AppendLine(basePrompt);
        sb.AppendLine();
        sb.AppendLine("## Current desktop context");
        Add(sb, "Foreground app", context.ForegroundApp);
        Add(sb, "Window title", context.ForegroundWindowTitle);
        Add(sb, "Workflow", context.Workflow.ToString());
        if (context.Browser is { Url: { Length: > 0 } } b)
        {
            Add(sb, "Browser URL", b.Url);
            Add(sb, "Browser title", b.Title);
            if (!string.IsNullOrEmpty(b.SelectedText))
                Add(sb, "Browser selection", b.SelectedText);
        }
        if (context.Ide is { HasContent: true } ide)
        {
            Add(sb, "IDE", ide.Editor);
            Add(sb, "Active file", ide.ActiveFile);
            Add(sb, "Repo", ide.RepoRoot);
            Add(sb, "Branch", ide.Branch);
        }
        if (!string.IsNullOrEmpty(context.SelectedText))
            Add(sb, $"Selected text ({context.SelectedTextType})", context.SelectedText);
        if (!string.IsNullOrEmpty(context.ClipboardSummary))
            Add(sb, $"Clipboard ({context.ClipboardType})", context.ClipboardSummary);
        if (!string.IsNullOrEmpty(context.RecentOcrSummary))
            Add(sb, "Recent OCR", context.RecentOcrSummary);
        if (context.LastHighlighted is { } t)
            Add(sb, "Last highlighted target", $"{t.Label} ({t.Source}, role={t.Role})");
        Add(sb, "Snapshot hash", context.SnapshotHash);
        return sb.ToString();
    }

    private static void Add(StringBuilder sb, string key, string? value)
    {
        if (string.IsNullOrEmpty(value)) return;
        sb.Append("- ").Append(key).Append(": ").AppendLine(value);
    }
}
