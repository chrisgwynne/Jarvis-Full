using FluentAssertions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Perception.Guidance;
using Xunit;

namespace Jarvis.Perception.Tests;

public class OcrGroupingTests
{
    private static OcrLine Line(string text, double x, double y, double w, double h) =>
        new(text, new[] { new OcrWord(text, 1.0, new OcrRect(x, y, w, h)) });

    [Fact]
    public void Long_paragraph_is_dropped()
    {
        var lines = new[]
        {
            Line("Lorem ipsum dolor sit amet consectetur adipiscing elit sed do", 10, 10, 400, 16)
        };
        var result = OcrTargetSource.GroupLinesIntoTargets(lines, new Rect(0, 0, 800, 600), null);
        result.Should().BeEmpty(because: "paragraphs are not button candidates");
    }

    [Fact]
    public void Adjacent_words_on_same_row_get_merged()
    {
        var lines = new[]
        {
            Line("Save",    20, 20, 30, 16),
            Line("Changes", 56, 20, 60, 16),
        };
        var result = OcrTargetSource.GroupLinesIntoTargets(lines, new Rect(0, 0, 800, 600), null);
        result.Should().HaveCount(1);
        result[0].Label.Should().Be("Save Changes");
        result[0].Bounds.Left.Should().Be(20);
        result[0].Bounds.Right.Should().Be(56 + 60);
    }

    [Fact]
    public void Far_apart_lines_are_kept_separate()
    {
        var lines = new[]
        {
            Line("Save",   20, 20, 30, 16),
            Line("Cancel", 500, 20, 60, 16),
        };
        var result = OcrTargetSource.GroupLinesIntoTargets(lines, new Rect(0, 0, 800, 600), null);
        result.Should().HaveCount(2);
    }

    [Fact]
    public void Tiny_lines_are_dropped()
    {
        var lines = new[]
        {
            Line("X", 0, 0, 4, 4) // below 8px floor
        };
        var result = OcrTargetSource.GroupLinesIntoTargets(lines, new Rect(0, 0, 800, 600), null);
        result.Should().BeEmpty();
    }

    [Fact]
    public void Result_has_screen_origin_offset()
    {
        var lines = new[] { Line("Save", 10, 10, 40, 16) };
        var result = OcrTargetSource.GroupLinesIntoTargets(lines, new Rect(200, 300, 1000, 800), null);
        result[0].Bounds.Left.Should().Be(210);
        result[0].Bounds.Top.Should().Be(310);
    }
}
