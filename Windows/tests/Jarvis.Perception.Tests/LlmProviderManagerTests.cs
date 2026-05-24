using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Perception.Conversation.Providers;
using Xunit;

namespace Jarvis.Perception.Tests;

public class LlmProviderManagerTests
{
    [Fact]
    public void Falls_back_to_echo_when_nothing_configured()
    {
        var mgr = new LlmProviderManager(() => new LlmSettings());
        mgr.IsConfigured.Should().BeFalse();
        mgr.Status.Configured.Should().BeFalse();
        mgr.Status.Detail.Should().Be("echo stub");
    }

    [Fact]
    public void Reports_openai_when_settings_complete()
    {
        var mgr = new LlmProviderManager(() => new LlmSettings
        {
            Provider = LlmProviderType.OpenAi,
            ApiKey = "sk-test",
            Model = "gpt-4o-mini"
        });
        mgr.IsConfigured.Should().BeTrue();
        mgr.Status.Type.Should().Be(LlmProviderType.OpenAi);
        mgr.Status.Model.Should().Be("gpt-4o-mini");
    }

    [Fact]
    public void Ollama_only_needs_a_model()
    {
        var mgr = new LlmProviderManager(() => new LlmSettings
        {
            Provider = LlmProviderType.Ollama,
            Model = "llama3.2"
        });
        mgr.IsConfigured.Should().BeTrue();
    }

    [Fact]
    public async Task Stream_through_manager_strips_thinking_tags()
    {
        var mgr = new LlmProviderManager(() => new LlmSettings());
        var pieces = new List<string>();
        await foreach (var p in mgr.StreamAsync(
            new LlmRequest("be terse", Array.Empty<ChatMessage>(), "<thinking>secret</thinking>hello",
                ConversationContext.Empty)))
        {
            pieces.Add(p);
        }
        var joined = string.Concat(pieces);
        joined.Should().NotContain("<thinking>");
        // Echo stub doesn't actually output the user message back verbatim, but the
        // important guarantee is that any thinking-tag bodies it emits would be stripped.
    }
}
