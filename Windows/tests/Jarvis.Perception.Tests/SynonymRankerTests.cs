using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class SynonymRankerTests
{
    private static UiTarget Tgt(string label, string role = "button", TargetSource source = TargetSource.UiAutomation,
        int x = 100, int y = 100, int w = 80, int h = 24) =>
        new(label, role, new Rect(x, y, x + w, y + h), 0.8, source, ActionHint: "click", Enabled: true);

    [Theory]
    [InlineData("submit", "Send")]
    [InlineData("submit", "Publish")]
    [InlineData("submit", "Post")]
    [InlineData("submit", "Share")]
    [InlineData("continue", "Next")]
    [InlineData("continue", "Proceed")]
    [InlineData("save", "Export")]
    [InlineData("save", "Download")]
    [InlineData("login", "Sign in")]
    [InlineData("create", "New")]
    [InlineData("create", "Add")]
    [InlineData("delete", "Remove")]
    [InlineData("delete", "Trash")]
    [InlineData("settings", "Preferences")]
    [InlineData("settings", "Options")]
    [InlineData("cancel", "Discard")]
    [InlineData("confirm", "OK")]
    public void Synonym_query_matches_target_label(string query, string label)
    {
        var noise = Tgt("Something unrelated");
        var hit = Tgt(label);
        var ranked = TargetRanker.Rank(query, new[] { noise, hit });
        ranked[0].Target.Label.Should().Be(label, because: $"'{query}' should pull '{label}' to the top");
    }

    [Fact]
    public void Primary_keyword_beats_synonym_when_both_present()
    {
        var primary = Tgt("Submit");
        var synonym = Tgt("Send");
        var ranked = TargetRanker.Rank("submit", new[] { synonym, primary });
        ranked[0].Target.Label.Should().Be("Submit");
        ranked[1].Target.Label.Should().Be("Send");
    }

    [Fact]
    public void Unknown_label_loses_to_a_synonym_match()
    {
        var unknown = Tgt("Frobnicate");
        var synonym = Tgt("Export", x: 600); // "save" synonym
        var ranked = TargetRanker.Rank("save", new[] { unknown, synonym });
        ranked[0].Target.Label.Should().Be("Export");
        ranked.First(c => c.Target.Label == "Frobnicate").Score
            .Should().BeLessThan(ranked.First(c => c.Target.Label == "Export").Score);
    }
}
