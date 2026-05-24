using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class ConversationExporterTests
{
    private static (List<ChatMessage> hist, List<ConversationDiagnostics> diag) BuildTurn(string user, string asst, LocalIntent intent)
    {
        var t0 = DateTimeOffset.Parse("2026-05-23T10:00:00Z");
        var hist = new List<ChatMessage>
        {
            new(ChatRole.User, user, t0),
            new(ChatRole.Assistant, asst, t0.AddSeconds(1), RoutedIntent: intent.ToString())
        };
        var diag = new List<ConversationDiagnostics>
        {
            new(t0, user, intent, "abc12345", LlmUsed: intent == LocalIntent.Unknown, 120, null, null)
        };
        return (hist, diag);
    }

    [Fact]
    public void Markdown_contains_user_and_assistant_blocks()
    {
        var (h, d) = BuildTurn("hello", "hi there", LocalIntent.Unknown);
        var md = ConversationExporter.ToMarkdown(h, d,
            new ConversationExportOptions("openAi · gpt-4o-mini", IncludeDebugMetadata: false));
        md.Should().Contain("## You · 10:00:00");
        md.Should().Contain("> hello");
        md.Should().Contain("## Jarvis · 10:00:01 · LLM");
        md.Should().Contain("hi there");
        md.Should().Contain("openAi · gpt-4o-mini");
    }

    [Fact]
    public void Routed_local_intent_label_replaces_LLM_tag()
    {
        var (h, d) = BuildTurn("what app", "you're in Code", LocalIntent.WhatApp);
        var md = ConversationExporter.ToMarkdown(h, d,
            new ConversationExportOptions(null, IncludeDebugMetadata: false));
        md.Should().Contain("WhatApp");
        md.Should().NotContain("· LLM");
    }

    [Fact]
    public void Debug_metadata_includes_snapshot_hash()
    {
        var (h, d) = BuildTurn("hi", "ok", LocalIntent.Unknown);
        var md = ConversationExporter.ToMarkdown(h, d,
            new ConversationExportOptions(null, IncludeDebugMetadata: true));
        md.Should().Contain("snapshot=abc12345");
    }

    [Fact]
    public void Multiline_user_message_is_quoted_across_lines()
    {
        var t0 = DateTimeOffset.Parse("2026-05-23T10:00:00Z");
        var h = new List<ChatMessage>
        {
            new(ChatRole.User, "line one\nline two", t0),
            new(ChatRole.Assistant, "ok", t0.AddSeconds(1), RoutedIntent: "Unknown")
        };
        var d = new List<ConversationDiagnostics>
        {
            new(t0, "line one\nline two", LocalIntent.Unknown, "h", true, 50, null, null)
        };
        var md = ConversationExporter.ToMarkdown(h, d, new ConversationExportOptions(null, false));
        md.Should().Contain("> line one");
        md.Should().Contain("> line two");
    }
}
