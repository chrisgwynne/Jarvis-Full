namespace Jarvis.Core.Conversation;

public sealed record ConversationTurn(
    ChatMessage User,
    LocalIntent RoutedIntent,
    /// <summary>The assistant message as it stands at end-of-turn. Streaming completed.</summary>
    ChatMessage Assistant,
    /// <summary>Per-turn diagnostics.</summary>
    ConversationDiagnostics Diagnostics);

public sealed record ConversationDiagnostics(
    DateTimeOffset At,
    string UserMessage,
    LocalIntent Intent,
    string SnapshotHash,
    bool LlmUsed,
    double TotalMs,
    string? ActionSummary,
    string? Error,
    string? ProviderType = null,
    string? Model = null,
    double? FirstTokenMs = null,
    int? OutputChars = null,
    RedactionReport? Redaction = null,
    string? CancelReason = null);

public interface IConversationService
{
    IReadOnlyList<ChatMessage> History { get; }

    /// <summary>One entry per completed assistant turn, in arrival order. Used by the
    /// exporter and the inspector.</summary>
    IReadOnlyList<ConversationDiagnostics> Diagnostics { get; }

    event EventHandler<ChatMessage>? MessageAppended;
    event EventHandler<ChatMessage>? StreamChunk;
    event EventHandler<ConversationTurn>? TurnCompleted;

    Task<ConversationTurn> SendAsync(string userMessage, CancellationToken cancellationToken = default);
    void Clear();
}
