using FluentAssertions;
using Jarvis.Core.Perception;
using Jarvis.Perception.Classification;
using Xunit;

namespace Jarvis.Perception.Tests;

public class SemanticContentClassifierTests
{
    private readonly SemanticContentClassifier _c = new();

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Empty_inputs_yield_unknown(string? input) =>
        _c.Classify(input).Should().Be(SemanticContentType.Unknown);

    [Theory]
    [InlineData("https://example.com")]
    [InlineData("http://example.com/path?x=1")]
    public void Detects_url(string input) =>
        _c.Classify(input).Should().Be(SemanticContentType.Url);

    [Fact]
    public void Detects_email() =>
        _c.Classify("user.name@example.co.uk").Should().Be(SemanticContentType.Email);

    [Fact]
    public void Detects_json()
    {
        _c.Classify("{\"a\": 1, \"b\": [2, 3]}").Should().Be(SemanticContentType.Json);
    }

    [Fact]
    public void Detects_sql() =>
        _c.Classify("SELECT id, name FROM users WHERE active = 1").Should().Be(SemanticContentType.Sql);

    [Fact]
    public void Detects_stack_trace()
    {
        var st = "Traceback (most recent call last):\n  File \"foo.py\", line 12, in bar\n    raise ValueError";
        _c.Classify(st).Should().Be(SemanticContentType.StackTrace);
    }

    [Fact]
    public void Detects_terminal_output()
    {
        _c.Classify("PS C:\\Users\\foo> dir\nMode  LastWriteTime").Should().Be(SemanticContentType.TerminalOutput);
    }

    [Fact]
    public void Detects_markdown()
    {
        _c.Classify("# Heading\n\n- item one\n- item two").Should().Be(SemanticContentType.Markdown);
    }

    [Fact]
    public void Detects_code()
    {
        var code = "public class Foo {\n  public int Bar() { return 1; }\n}";
        _c.Classify(code).Should().Be(SemanticContentType.Code);
    }

    [Fact]
    public void Detects_table_with_tabs()
    {
        var table = "name\tage\nalice\t30\nbob\t25\n";
        _c.Classify(table).Should().Be(SemanticContentType.Table);
    }

    [Fact]
    public void Long_prose_falls_through_to_prose() =>
        _c.Classify("This is a regular sentence describing something at length.").Should().Be(SemanticContentType.Prose);

    [Fact]
    public void Url_beats_prose_even_with_trailing_spaces() =>
        _c.Classify("  https://example.com  ").Should().Be(SemanticContentType.Url);

    [Fact]
    public void Stack_trace_beats_code_when_both_match()
    {
        var mixed = "at System.Foo.Bar() in C:\\foo.cs:line 42\npublic void Bar() { }";
        _c.Classify(mixed).Should().Be(SemanticContentType.StackTrace);
    }
}
