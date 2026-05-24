using System.Text.Json.Nodes;
using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Perception.Conversation.Providers;
using Xunit;

namespace Jarvis.Perception.Tests;

/// <summary>
/// Offline tests for the request bodies each provider emits. We exercise the JSON
/// shape without making any HTTP calls. Spec changes here would be flagged immediately
/// by a real provider returning 400.
/// </summary>
public class ProviderRequestShapeTests
{
    private static LlmRequest Req() => new(
        SystemPrompt: "be terse",
        History: new[] { new ChatMessage(ChatRole.User, "earlier", DateTimeOffset.UtcNow) },
        UserMessage: "hello",
        Context: ConversationContext.Empty with { ForegroundApp = "Code" });

    [Fact]
    public void OpenAi_body_has_messages_with_system_first()
    {
        var s = new LlmSettings { Model = "gpt-4o-mini", Temperature = 0.3, MaxTokens = 256, Stream = true };
        var body = OpenAiLlmClient.BuildBody(Req(), s);
        var json = JsonNode.Parse(body)!;
        json["model"]!.GetValue<string>().Should().Be("gpt-4o-mini");
        json["stream"]!.GetValue<bool>().Should().BeTrue();
        var messages = (JsonArray)json["messages"]!;
        messages.Count.Should().Be(3);
        messages[0]!["role"]!.GetValue<string>().Should().Be("system");
        messages[0]!["content"]!.GetValue<string>().Should().Contain("Code"); // context injected
        messages[1]!["role"]!.GetValue<string>().Should().Be("user");
        messages[2]!["role"]!.GetValue<string>().Should().Be("user");
        messages[2]!["content"]!.GetValue<string>().Should().Be("hello");
    }

    [Fact]
    public void Ollama_body_uses_options_block_for_temperature()
    {
        var s = new LlmSettings { Model = "llama3.2", Temperature = 0.2, MaxTokens = 1024, Stream = true };
        var body = OllamaLlmClient.BuildBody(Req(), s);
        var json = JsonNode.Parse(body)!;
        json["model"]!.GetValue<string>().Should().Be("llama3.2");
        json["stream"]!.GetValue<bool>().Should().BeTrue();
        json["options"]!["temperature"]!.GetValue<double>().Should().Be(0.2);
        json["options"]!["num_predict"]!.GetValue<int>().Should().Be(1024);
    }
}
