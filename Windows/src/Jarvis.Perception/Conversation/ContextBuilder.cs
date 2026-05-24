using Jarvis.Core.Conversation;
using Jarvis.Core.Guidance;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Projects PerceptionService + GuidanceService state into the compact
/// <see cref="ConversationContext"/> the chat layer cares about.
/// </summary>
public sealed class ContextBuilder : IConversationContextBuilder
{
    private readonly PerceptionService _perception;
    private readonly IGuidanceService _guidance;

    public ContextBuilder(PerceptionService perception, IGuidanceService guidance)
    {
        _perception = perception;
        _guidance = guidance;
    }

    public ConversationContext Build()
    {
        var snap = _perception.BuildCurrent();
        return new ConversationContext(
            CapturedAt: DateTimeOffset.UtcNow,
            ForegroundApp: snap.ForegroundApp,
            ForegroundWindowTitle: snap.ForegroundWindowTitle,
            Workflow: snap.Workflow,
            SelectedText: snap.SelectedText,
            SelectedTextType: snap.SelectedTextType,
            ClipboardSummary: snap.ClipboardSummary,
            ClipboardType: snap.ClipboardType,
            Browser: snap.Browser,
            Ide: snap.Ide,
            RecentOcrSummary: snap.RecentOcrSummary,
            LastHighlighted: _guidance.LastHighlighted,
            SnapshotHash: snap.Hash);
    }
}
