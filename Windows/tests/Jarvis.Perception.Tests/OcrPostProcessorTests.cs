using FluentAssertions;
using Jarvis.Perception.Ocr;
using Xunit;

namespace Jarvis.Perception.Tests;

public class OcrPostProcessorTests
{
    private readonly OcrPostProcessor _p = new();

    [Fact]
    public void Empty_input_returns_empty() => _p.Clean("").Should().Be("");

    [Fact]
    public void Collapses_runs_of_blank_lines()
    {
        var input = "a\n\n\n\nb";
        _p.Clean(input).Should().Be("a\n\nb");
    }

    [Fact]
    public void Normalizes_smart_quotes_and_dashes()
    {
        var input = "“hello” ‘world’ — fine";
        _p.Clean(input).Should().Be("\"hello\" 'world' - fine");
    }

    [Fact]
    public void Trims_trailing_whitespace_on_lines()
    {
        var input = "foo   \nbar\t \nbaz";
        _p.Clean(input).Should().Be("foo\nbar\nbaz");
    }

    [Fact]
    public void Collapses_internal_multiple_spaces()
    {
        _p.Clean("hello    world").Should().Be("hello world");
    }

    [Fact]
    public void Strips_table_border_pipes()
    {
        var input = "| name | age |\n| alice | 30 |";
        _p.Clean(input).Should().Be("name | age\nalice | 30");
    }

    [Fact]
    public void Handles_crlf()
    {
        _p.Clean("a\r\nb\r\nc").Should().Be("a\nb\nc");
    }
}
