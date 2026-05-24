using FluentAssertions;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class ThinkingTagStripperTests
{
    [Fact]
    public void Inline_thinking_block_is_stripped()
    {
        var s = new ThinkingTagStripper();
        var output = s.Push("Hello <thinking>internal</thinking>world.");
        output += s.Flush();
        output.Should().Be("Hello world.");
    }

    [Fact]
    public void Tag_split_across_chunks_is_still_caught()
    {
        var s = new ThinkingTagStripper();
        var output = s.Push("Hello <thin");
        output += s.Push("king>internal</thinking>world.");
        output += s.Flush();
        output.Should().Be("Hello world.");
    }

    [Fact]
    public void Close_split_across_chunks_works()
    {
        var s = new ThinkingTagStripper();
        var output = s.Push("Hi <thinking>secret</thi");
        output += s.Push("nking>visible");
        output += s.Flush();
        output.Should().Be("Hi visible");
    }

    [Fact]
    public void Unterminated_tag_swallows_remainder()
    {
        var s = new ThinkingTagStripper();
        var output = s.Push("before <thinking>unterminated forever");
        output += s.Flush();
        output.Should().Be("before ");
    }

    [Fact]
    public void Other_tags_pass_through()
    {
        var s = new ThinkingTagStripper();
        var output = s.Push("<emphasis>kept</emphasis>");
        output += s.Flush();
        output.Should().Be("<emphasis>kept</emphasis>");
    }

    [Fact]
    public void Reasoning_and_scratchpad_tags_also_strip()
    {
        var s = new ThinkingTagStripper();
        var a = s.Push("a<reasoning>r</reasoning>b<scratchpad>s</scratchpad>c");
        a += s.Flush();
        a.Should().Be("abc");
    }
}
