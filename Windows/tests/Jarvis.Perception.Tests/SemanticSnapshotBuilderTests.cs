using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Classification;
using Jarvis.Perception.Snapshot;
using Xunit;

namespace Jarvis.Perception.Tests;

public class SemanticSnapshotBuilderTests
{
    private readonly SemanticSnapshotBuilder _b = new(new SemanticContentClassifier(), new WorkflowCategorizer());

    private static DesktopSnapshot Desktop(string app) =>
        new(DateTimeOffset.UtcNow, app, app + " - Foo", IntPtr.Zero, 0, Rect.Empty, TimeSpan.Zero, true);

    [Fact]
    public void Builds_from_empty_inputs()
    {
        var snap = _b.Build(new SemanticSnapshotInputs(null, null, null, null, null, null));
        snap.Workflow.Should().Be(WorkflowCategory.Unknown);
        snap.Hash.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public void Hash_changes_when_inputs_change()
    {
        var a = _b.Build(new SemanticSnapshotInputs(Desktop("Code"), null, null, null, null, null));
        var b = _b.Build(new SemanticSnapshotInputs(Desktop("chrome"), null, null, null, null, null));
        a.Hash.Should().NotBe(b.Hash);
    }

    [Fact]
    public void Hash_stable_for_same_inputs()
    {
        var inputs = new SemanticSnapshotInputs(Desktop("Code"), null, null, null, null, null);
        _b.Build(inputs).Hash.Should().Be(_b.Build(inputs).Hash);
    }

    [Fact]
    public void Classifies_selected_text()
    {
        var sel = new SelectedTextSnapshot(DateTimeOffset.UtcNow, "SELECT * FROM users", "Code", null, null, null, true);
        var snap = _b.Build(new SemanticSnapshotInputs(Desktop("Code"), sel, null, null, null, null));
        snap.SelectedTextType.Should().Be(SemanticContentType.Sql);
        snap.Workflow.Should().Be(WorkflowCategory.Coding);
    }

    [Fact]
    public void Truncates_selected_text_to_max()
    {
        var huge = new string('x', 10_000);
        var sel = new SelectedTextSnapshot(DateTimeOffset.UtcNow, huge, "Code", null, null, null, true);
        var snap = _b.Build(new SemanticSnapshotInputs(Desktop("Code"), sel, null, null, null, null));
        snap.SelectedText!.Length.Should().Be(4_000);
    }
}
