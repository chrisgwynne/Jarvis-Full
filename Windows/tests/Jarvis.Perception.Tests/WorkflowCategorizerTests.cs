using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Snapshot;
using Xunit;

namespace Jarvis.Perception.Tests;

public class WorkflowCategorizerTests
{
    private readonly WorkflowCategorizer _c = new();

    private static DesktopSnapshot Desktop(string app, bool active = true) =>
        new(DateTimeOffset.UtcNow, app, app + " - Foo", IntPtr.Zero, 0, Rect.Empty, TimeSpan.Zero, active);

    [Fact]
    public void Unknown_when_no_desktop() =>
        _c.Categorize(new SemanticSnapshotInputs(null, null, null, null, null, null))
            .Should().Be(WorkflowCategory.Unknown);

    [Fact]
    public void Idle_when_user_inactive() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("Code", active: false), null, null, null, null, null))
            .Should().Be(WorkflowCategory.Idle);

    [Fact]
    public void Coding_for_vscode() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("Code"), null, null, null, null, null))
            .Should().Be(WorkflowCategory.Coding);

    [Fact]
    public void Debugging_when_stack_trace_in_clipboard_in_terminal()
    {
        var clip = new ClipboardEntry(DateTimeOffset.UtcNow, SemanticContentType.StackTrace,
            "Traceback…", null, null, "WindowsTerminal", "h");
        _c.Categorize(new SemanticSnapshotInputs(Desktop("WindowsTerminal"), null, clip, null, null, null))
            .Should().Be(WorkflowCategory.Debugging);
    }

    [Fact]
    public void Terminal_work_for_wt() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("WindowsTerminal"), null, null, null, null, null))
            .Should().Be(WorkflowCategory.TerminalWork);

    [Fact]
    public void Browsing_for_chrome_without_shopping_signals() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("chrome"), null, null,
            new BrowserContextSnapshot(DateTimeOffset.UtcNow, "Chrome", "https://news.example.com", "news.example.com", "Daily news", null, null, false), null, null))
            .Should().Be(WorkflowCategory.Browsing);

    [Fact]
    public void Shopping_when_browser_url_hints_shopping() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("chrome"), null, null,
            new BrowserContextSnapshot(DateTimeOffset.UtcNow, "Chrome", "https://www.amazon.com/cart", "amazon.com", "Cart", null, null, false), null, null))
            .Should().Be(WorkflowCategory.Shopping);

    [Fact]
    public void Communication_for_slack() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("slack"), null, null, null, null, null))
            .Should().Be(WorkflowCategory.Communication);

    [Fact]
    public void Writing_for_obsidian() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("obsidian"), null, null, null, null, null))
            .Should().Be(WorkflowCategory.Writing);

    [Fact]
    public void Editing_for_photoshop() =>
        _c.Categorize(new SemanticSnapshotInputs(Desktop("Photoshop"), null, null, null, null, null))
            .Should().Be(WorkflowCategory.Editing);
}
