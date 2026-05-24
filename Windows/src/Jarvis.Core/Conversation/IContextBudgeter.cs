namespace Jarvis.Core.Conversation;

public interface IContextBudgeter
{
    /// <summary>Return a compact version of <paramref name="context"/> with secrets
    /// redacted and long fields truncated, suitable for sending to a cloud LLM. The
    /// returned object MUST be safe to log.</summary>
    (ConversationContext Compact, RedactionReport Report) Budget(ConversationContext context);
}
