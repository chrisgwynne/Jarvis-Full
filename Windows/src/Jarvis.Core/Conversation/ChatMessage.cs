namespace Jarvis.Core.Conversation;

public enum ChatRole
{
    User,
    Assistant,
    System
}

public sealed record ChatMessage(
    ChatRole Role,
    string Content,
    DateTimeOffset At,
    /// <summary>Set on the User message that triggered a local intent — useful for the
    /// inspector and audit. Null for assistant streams and pure LLM passthroughs.</summary>
    string? RoutedIntent = null,
    /// <summary>Marks chunks that are still arriving from a streaming response.
    /// The renderer can show a caret/blink while this is true.</summary>
    bool Streaming = false);
