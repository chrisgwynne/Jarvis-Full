using System.Text.Json.Serialization;

namespace Jarvis.Core.Logging;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ReplySource
{
    Command,      // routed command via template/response library
    Template,     // explicit key lookup
    Llm,          // LLM-generated response
    Tool,         // tool execution result
    Proactive,    // unsolicited nudge
    Error,        // error/failure path
    Wake,         // wake word acknowledgement
    System        // internal system message — not user-editable
}

public sealed record ReplyLogEntry(
    Guid Id,
    DateTimeOffset Timestamp,
    ReplySource Source,
    string? Intent,
    string? ResponseKey,
    string SpokenText,
    string Device,
    bool EditableFlag,
    string? CorrectedText = null,
    bool? Accepted = null);
