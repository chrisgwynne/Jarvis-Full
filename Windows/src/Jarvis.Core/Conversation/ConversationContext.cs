using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;

namespace Jarvis.Core.Conversation;

/// <summary>
/// Compact projection of "everything Jarvis can reasonably know right now". Built once
/// per user turn and either consumed by the local router or serialised into the LLM
/// system message. Keep this small — every field is a deliberate inclusion.
/// </summary>
public sealed record ConversationContext(
    DateTimeOffset CapturedAt,
    string? ForegroundApp,
    string? ForegroundWindowTitle,
    WorkflowCategory Workflow,
    string? SelectedText,
    SemanticContentType SelectedTextType,
    string? ClipboardSummary,
    SemanticContentType ClipboardType,
    BrowserContextSnapshot? Browser,
    IdeContext? Ide,
    string? RecentOcrSummary,
    UiTarget? LastHighlighted,
    /// <summary>Same hash as the underlying SemanticSnapshot. Lets the LLM (or audit)
    /// reason about whether two turns saw the same desktop state.</summary>
    string SnapshotHash)
{
    public static ConversationContext Empty => new(
        DateTimeOffset.UtcNow, null, null, WorkflowCategory.Unknown, null,
        SemanticContentType.Unknown, null, SemanticContentType.Unknown, null, null, null, null, "0");
}

public interface IConversationContextBuilder
{
    /// <summary>Build a fresh context snapshot. Cheap; called once per user message.</summary>
    ConversationContext Build();
}
