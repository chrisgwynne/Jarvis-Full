using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class TargetRankerTests
{
    private static UiTarget Tgt(string label, string role, TargetSource source,
        int x = 100, int y = 100, int w = 80, int h = 24,
        bool enabled = true, double confidence = 0.8, string? process = null) =>
        new(label, role, new Rect(x, y, x + w, y + h), confidence, source,
            ActionHint: "click", Enabled: enabled, Process: process);

    [Fact]
    public void Exact_label_match_wins_over_role_match()
    {
        var save = Tgt("Save", "button", TargetSource.UiAutomation);
        var save_as = Tgt("Save As…", "button", TargetSource.UiAutomation);
        var ranked = TargetRanker.Rank("save", new[] { save, save_as });
        ranked[0].Target.Should().Be(save);
    }

    [Fact]
    public void BrowserDom_beats_UIA_with_equal_label_match()
    {
        var dom = Tgt("Continue", "button", TargetSource.BrowserDom);
        var uia = Tgt("Continue", "button", TargetSource.UiAutomation);
        var ranked = TargetRanker.Rank("continue", new[] { uia, dom });
        ranked[0].Target.Source.Should().Be(TargetSource.BrowserDom);
    }

    [Fact]
    public void UIA_beats_OCR_with_equal_label_match()
    {
        var uia = Tgt("Save", "button", TargetSource.UiAutomation);
        var ocr = Tgt("Save", "button", TargetSource.Ocr, confidence: 0.4);
        var ranked = TargetRanker.Rank("save", new[] { ocr, uia });
        ranked[0].Target.Source.Should().Be(TargetSource.UiAutomation);
    }

    [Fact]
    public void Disabled_target_loses_to_enabled_same_label()
    {
        var disabled = Tgt("Continue", "button", TargetSource.UiAutomation, enabled: false);
        var enabled = Tgt("Continue", "button", TargetSource.UiAutomation, x: 500);
        var ranked = TargetRanker.Rank("continue", new[] { disabled, enabled });
        ranked[0].Target.Should().Be(enabled);
    }

    [Fact]
    public void Role_hint_boosts_button_for_save_query()
    {
        var savedDoc = Tgt("Saved documents", "text", TargetSource.UiAutomation);
        var saveBtn = Tgt("Save document", "button", TargetSource.UiAutomation);
        var ranked = TargetRanker.Rank("save", new[] { savedDoc, saveBtn });
        ranked[0].Target.Should().Be(saveBtn);
    }

    [Fact]
    public void Role_hint_boosts_textbox_for_type_query()
    {
        var btn = Tgt("Search", "button", TargetSource.UiAutomation);
        var input = Tgt("Search", "textbox", TargetSource.UiAutomation);
        var ranked = TargetRanker.Rank("type into search", new[] { btn, input });
        ranked[0].Target.Should().Be(input);
    }

    [Fact]
    public void Empty_query_returns_targets_with_low_scores()
    {
        var ranked = TargetRanker.Rank("", new[] {
            Tgt("Save", "button", TargetSource.UiAutomation),
            Tgt("Open", "button", TargetSource.UiAutomation)
        });
        ranked.Should().NotBeEmpty();
        ranked.All(c => c.Score < 0.5).Should().BeTrue();
    }

    [Fact]
    public void Invalid_targets_are_dropped()
    {
        var ranked = TargetRanker.Rank("save", new[] {
            new UiTarget("", "button", new Rect(0,0,10,10), 1, TargetSource.UiAutomation),
            Tgt("Save", "button", TargetSource.UiAutomation)
        });
        ranked.Should().HaveCount(1);
    }

    [Fact]
    public void Cursor_proximity_breaks_ties_when_labels_equal()
    {
        var near = Tgt("Continue", "button", TargetSource.UiAutomation, x: 100, y: 100);
        var far  = Tgt("Continue", "button", TargetSource.UiAutomation, x: 1800, y: 900);
        var ranked = TargetRanker.Rank("continue", new[] { far, near }, cursorX: 100, cursorY: 100);
        ranked[0].Target.Should().Be(near);
    }

    [Fact]
    public void Foreground_process_match_breaks_ties()
    {
        var foreground = Tgt("Save", "button", TargetSource.UiAutomation, process: "Code");
        var other      = Tgt("Save", "button", TargetSource.UiAutomation, process: "explorer", x: 500);
        var ranked = TargetRanker.Rank("save", new[] { other, foreground }, foregroundProcess: "Code");
        ranked[0].Target.Process.Should().Be("Code");
    }

    [Fact]
    public void Keyword_extraction_strips_stopwords()
    {
        var keywords = TargetRanker.ExtractKeywords("Where do I click to save this?");
        keywords.Should().Equal("save");
    }

    [Fact]
    public void Label_score_returns_1_on_exact_match()
    {
        TargetRanker.LabelScore(new[] { "save" }, "Save").Should().Be(1.0);
    }
}
