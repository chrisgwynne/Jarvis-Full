using Jarvis.Core.Awareness;
using Jarvis.Core.Perception;

namespace Jarvis.Core.Snapshot;

public enum WorkflowCategory
{
    Unknown,
    Idle,
    Coding,
    Debugging,
    Browsing,
    Research,
    Writing,
    Reading,
    Shopping,
    Editing,
    TerminalWork,
    Communication,
    Media
}

/// <summary>
/// Compact snapshot of the user's current desktop context. Built by merging awareness,
/// selected text, clipboard, browser, and (optionally) recent OCR. Designed to be cheap
/// to produce (no I/O) and small enough to send to an LLM as a system message.
/// </summary>
public sealed record SemanticSnapshot(
    DateTimeOffset CapturedAt,
    string? ForegroundApp,
    string? ForegroundWindowTitle,
    string? SelectedText,
    SemanticContentType SelectedTextType,
    string? ClipboardSummary,
    SemanticContentType ClipboardType,
    BrowserContextSnapshot? Browser,
    IdeContext? Ide,
    string? RecentOcrSummary,
    WorkflowCategory Workflow,
    string Hash)
{
    public static SemanticSnapshot Empty => new(
        CapturedAt: DateTimeOffset.UtcNow,
        ForegroundApp: null,
        ForegroundWindowTitle: null,
        SelectedText: null,
        SelectedTextType: SemanticContentType.Unknown,
        ClipboardSummary: null,
        ClipboardType: SemanticContentType.Unknown,
        Browser: null,
        Ide: null,
        RecentOcrSummary: null,
        Workflow: WorkflowCategory.Unknown,
        Hash: "0");
}

public sealed record SemanticSnapshotInputs(
    DesktopSnapshot? Desktop,
    SelectedTextSnapshot? Selection,
    ClipboardEntry? Clipboard,
    BrowserContextSnapshot? Browser,
    IdeContext? Ide,
    OcrResult? RecentOcr);

public interface ISemanticSnapshotBuilder
{
    SemanticSnapshot Build(SemanticSnapshotInputs inputs);
}

public interface IWorkflowCategorizer
{
    WorkflowCategory Categorize(SemanticSnapshotInputs inputs);
}
