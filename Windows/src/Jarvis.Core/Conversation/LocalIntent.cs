namespace Jarvis.Core.Conversation;

/// <summary>
/// Pre-LLM intent categories the local router recognises. Order doesn't matter; the
/// router pattern-matches by phrase. Anything not in this list falls through to the LLM
/// (or to a "not configured" placeholder when no LLM is wired).
/// </summary>
public enum LocalIntent
{
    /// <summary>Fell through. Hand to LLM.</summary>
    Unknown,

    /// <summary>"where do I click to X" — call IGuidanceService.AskAsync.</summary>
    WhereDoIClick,

    /// <summary>"click it" / "do it" / "press it" — click the last highlighted target.</summary>
    ClickLastTarget,

    /// <summary>"highlight the save button" — guidance without the suggested click.</summary>
    HighlightTarget,

    /// <summary>"what app am I in" — read foreground.</summary>
    WhatApp,

    /// <summary>"what page is this" — read browser context.</summary>
    WhatPage,

    /// <summary>"what did I select" — return the current selection.</summary>
    WhatSelection,

    /// <summary>"what's on my clipboard" — return the clipboard summary.</summary>
    WhatClipboard,

    /// <summary>"summarise selected text" — needs LLM, but pre-baked the selection into context.</summary>
    SummariseSelection,

    /// <summary>"ocr this" / "what does this say" — trigger region capture.</summary>
    OcrRegion,

    /// <summary>"close menu" / "hide menu" / "dismiss menu" — closes the Pebble
    /// Interaction Menu if open. No-op otherwise.</summary>
    CloseInteractionMenu
}

/// <summary>
/// Result of routing. A handler may complete inline (sync reply) or hand off to a
/// streaming response. Either way the assistant gets exactly one message back.
/// </summary>
public sealed record RoutedReply(
    LocalIntent Intent,
    string? InlineReply,
    IAsyncEnumerable<string>? Stream,
    /// <summary>Set when the route also kicked off an action (click, capture, …).
    /// Just metadata — the action is fire-and-forget by the time we return.</summary>
    string? ActionSummary,
    bool RequiresLlm)
{
    public static RoutedReply Local(LocalIntent intent, string reply, string? action = null) =>
        new(intent, reply, null, action, RequiresLlm: false);
    public static RoutedReply Streaming(LocalIntent intent, IAsyncEnumerable<string> stream, string? action = null) =>
        new(intent, null, stream, action, RequiresLlm: false);
    public static RoutedReply PassThroughToLlm() =>
        new(LocalIntent.Unknown, null, null, null, RequiresLlm: true);
}

public interface ILocalIntentRouter
{
    /// <summary>Match an intent or return Unknown. Stateless.</summary>
    LocalIntent Classify(string userMessage);

    /// <summary>Execute the matched route. May produce a sync or streaming reply.
    /// Implementations have side effects (highlight + click) for action intents.</summary>
    Task<RoutedReply> RouteAsync(LocalIntent intent, string userMessage, ConversationContext context, CancellationToken cancellationToken);
}
