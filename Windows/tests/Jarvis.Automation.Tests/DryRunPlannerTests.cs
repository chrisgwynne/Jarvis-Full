using FluentAssertions;
using Jarvis.Automation;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class DryRunPlannerTests
{
    private readonly DryRunPlanner _planner = new(new DefaultApprovalPolicy());

    [Fact]
    public void Plan_passes_through_safety_tier()
    {
        var plan = _planner.Plan(new TypeTextIntent("hello"));
        plan.Safety.Tier.Should().Be(SafetyTier.Approve);
    }

    [Fact]
    public void Plan_for_paste_lists_clipboard_restore_step()
    {
        var plan = _planner.Plan(new PasteTextIntent("yo"));
        plan.Steps.Should().ContainMatch("*Restore prior clipboard*");
        plan.UndoHint.Should().Contain("Ctrl+Z");
    }

    [Fact]
    public void Plan_for_create_draft_includes_path_and_undo_hint()
    {
        var plan = _planner.Plan(new CreateDraftFileIntent(@"C:\Users\me\note.txt", "hi"));
        plan.Target.Should().Contain("note.txt");
        plan.UndoHint.Should().Contain("Delete the file");
    }

    [Fact]
    public void Plan_for_reveal_has_no_undo_hint()
    {
        var plan = _planner.Plan(new RevealFileIntent(@"C:\foo"));
        plan.UndoHint.Should().BeNull();
    }

    [Fact]
    public void Plan_for_blocked_intent_still_returns_block_tier()
    {
        var plan = _planner.Plan(new OpenAppIntent("powershell.exe"));
        plan.Safety.Tier.Should().Be(SafetyTier.Block);
        plan.Headline.Should().Contain("powershell");
    }

    [Fact]
    public void Plan_for_focus_describes_target_process()
    {
        var plan = _planner.Plan(new FocusWindowIntent("Code"));
        plan.Target.Should().Be("process=Code");
    }
}
