namespace Jarvis.Core.Conversation;

public sealed record LlmRequest(
    string SystemPrompt,
    IReadOnlyList<ChatMessage> History,
    string UserMessage,
    ConversationContext Context);

/// <summary>
/// Abstraction over the chat backend. The P5 stub is a streaming echo client; future
/// implementations plug in OpenAI/MiniMax/local-model adapters without touching the
/// router or UI. Streaming via IAsyncEnumerable so the panel can render incrementally.
/// </summary>
public interface ILlmClient
{
    /// <summary>True when the client can actually produce content. Stubs return false so
    /// the router can render a placeholder explanation instead of "..."</summary>
    bool IsConfigured { get; }

    IAsyncEnumerable<string> StreamAsync(LlmRequest request, CancellationToken cancellationToken = default);
}
