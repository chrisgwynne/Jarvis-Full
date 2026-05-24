using System.Text.RegularExpressions;
using Jarvis.Core.Automation;
using Jarvis.Core.Conversation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Deterministic phrase matcher + executor for the obvious local intents the chat panel
/// should handle without round-tripping an LLM. Order is important: more specific
/// patterns are tested first.
///
/// All execution is read-only OR routed through existing approval-gated systems:
///   - <see cref="LocalIntent.ClickLastTarget"/> uses <see cref="IAutomationExecutor"/>
///     so the click hits the Approve-tier modal — never autonomous.
///   - <see cref="LocalIntent.HighlightTarget"/> draws the visual highlight only; no click.
///   - Read intents (WhatApp / WhatPage / WhatSelection / WhatClipboard) touch no state.
/// </summary>
public sealed partial class LocalIntentRouter : ILocalIntentRouter
{
    [GeneratedRegex(@"\b(where (do|should) (i|we) click|click where|where to click|where (is|to) (the )?(button|button to))\b", RegexOptions.IgnoreCase)]
    private static partial Regex WhereDoIClickPattern();

    [GeneratedRegex(@"^\s*(click|press|tap|do|hit)\s+(it|that|there|this( one)?|the (one|button))(\s+(now|please|then))?\s*[!\.\?]*\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex ClickItPattern();

    [GeneratedRegex(@"\bhighlight\s+(the\s+)?(\w[\w \-]{0,40})\b", RegexOptions.IgnoreCase)]
    private static partial Regex HighlightPattern();

    [GeneratedRegex(@"\b(what|which)\s+app(\s+am\s+i\s+in)?\b|^\s*current app\s*\??\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex WhatAppPattern();

    [GeneratedRegex(@"\b(what|which)\s+(page|tab|site|url)\b", RegexOptions.IgnoreCase)]
    private static partial Regex WhatPagePattern();

    [GeneratedRegex(@"\bwhat\s+(did\s+i\s+select|is\s+selected|am\s+i\s+selecting)\b|\bmy\s+selection\b", RegexOptions.IgnoreCase)]
    private static partial Regex WhatSelectionPattern();

    [GeneratedRegex(@"\b(what'?s on (my )?clipboard|read (my )?clipboard|what (did i )?copy)\b", RegexOptions.IgnoreCase)]
    private static partial Regex WhatClipboardPattern();

    [GeneratedRegex(@"\b(summari[sz]e|tldr|tl;dr|tldr;)\b.*\b(selection|selected|highlighted|this)\b", RegexOptions.IgnoreCase)]
    private static partial Regex SummariseSelectionPattern();

    [GeneratedRegex(@"\b(ocr|read|extract|grab text|what does this say|what does that say)\b", RegexOptions.IgnoreCase)]
    private static partial Regex OcrPattern();

    [GeneratedRegex(@"^\s*(close|hide|dismiss)\s+(the\s+)?menu\s*[!\.\?]*\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex CloseMenuPattern();

    private readonly IGuidanceService _guidance;
    private readonly IAutomationExecutor _executor;
    private readonly IHighlightRenderer _highlighter;
    private Func<CancellationToken, Task<string?>>? _captureRegion;

    /// <summary>Set after DI is built so the chat layer can invoke the app's region
    /// capture + OCR flow without forcing the perception layer to take a Jarvis.App dependency.</summary>
    public Func<CancellationToken, Task<string?>>? CaptureRegionHook
    {
        get => _captureRegion;
        set => _captureRegion = value;
    }

    /// <summary>Set after DI is built so "close menu" voice/chat commands can close the
    /// Pebble Interaction Menu without coupling the perception layer to WPF.</summary>
    public Action? CloseInteractionMenuHook { get; set; }
    private readonly IDiagnostics? _diagnostics;

    public LocalIntentRouter(
        IGuidanceService guidance,
        IAutomationExecutor executor,
        IHighlightRenderer highlighter,
        Func<CancellationToken, Task<string?>>? captureRegion = null,
        IDiagnostics? diagnostics = null)
    {
        _guidance = guidance;
        _executor = executor;
        _highlighter = highlighter;
        _captureRegion = captureRegion;
        _diagnostics = diagnostics;
    }

    public LocalIntent Classify(string userMessage)
    {
        if (string.IsNullOrWhiteSpace(userMessage)) return LocalIntent.Unknown;
        var m = userMessage.Trim();

        // Specific phrases beat substring matchers.
        if (CloseMenuPattern().IsMatch(m)) return LocalIntent.CloseInteractionMenu;
        if (ClickItPattern().IsMatch(m)) return LocalIntent.ClickLastTarget;
        if (WhereDoIClickPattern().IsMatch(m)) return LocalIntent.WhereDoIClick;
        if (HighlightPattern().IsMatch(m)) return LocalIntent.HighlightTarget;
        if (SummariseSelectionPattern().IsMatch(m)) return LocalIntent.SummariseSelection;
        if (WhatSelectionPattern().IsMatch(m)) return LocalIntent.WhatSelection;
        if (WhatClipboardPattern().IsMatch(m)) return LocalIntent.WhatClipboard;
        if (WhatPagePattern().IsMatch(m)) return LocalIntent.WhatPage;
        if (WhatAppPattern().IsMatch(m)) return LocalIntent.WhatApp;
        if (OcrPattern().IsMatch(m)) return LocalIntent.OcrRegion;
        return LocalIntent.Unknown;
    }

    public async Task<RoutedReply> RouteAsync(LocalIntent intent, string userMessage, ConversationContext context, CancellationToken cancellationToken)
    {
        _diagnostics?.Record(DiagnosticLevel.Debug, "conversation.route", intent.ToString(),
            new Dictionary<string, object?> { ["msg"] = userMessage, ["snapshot"] = context.SnapshotHash });

        switch (intent)
        {
            case LocalIntent.WhatApp:
                return RoutedReply.Local(intent,
                    string.IsNullOrEmpty(context.ForegroundApp)
                        ? "I can't see a foreground app right now."
                        : $"You're in **{context.ForegroundApp}** — {context.ForegroundWindowTitle ?? "(no title)"}.");

            case LocalIntent.WhatPage:
                if (context.Browser is { Url: { Length: > 0 } } b)
                    return RoutedReply.Local(intent,
                        $"**{b.Title ?? "(untitled)"}** at `{b.Url}` ({b.Domain ?? "unknown domain"}).");
                return RoutedReply.Local(intent, "No browser extension is connected, or no tab is in the foreground.");

            case LocalIntent.WhatSelection:
                return string.IsNullOrEmpty(context.SelectedText)
                    ? RoutedReply.Local(intent, "Nothing selected in the foreground window.")
                    : RoutedReply.Local(intent,
                        $"Selected text ({context.SelectedTextType}): \"{Truncate(context.SelectedText, 600)}\"");

            case LocalIntent.WhatClipboard:
                return string.IsNullOrEmpty(context.ClipboardSummary)
                    ? RoutedReply.Local(intent, "Clipboard is empty (or nothing has been copied since Jarvis started).")
                    : RoutedReply.Local(intent,
                        $"Clipboard ({context.ClipboardType}): \"{Truncate(context.ClipboardSummary, 400)}\"");

            case LocalIntent.WhereDoIClick:
            case LocalIntent.HighlightTarget:
            {
                var query = StripGuidancePreamble(userMessage);
                var result = await _guidance.AskAsync(query, cancellationToken).ConfigureAwait(false);
                var reply = result.Found
                    ? result.Explanation + (intent == LocalIntent.WhereDoIClick && result.SuggestedClick is not null
                        ? "\n\n_Say \"click it\" or press Ctrl+Shift+Enter to click._"
                        : "")
                    : result.Explanation;
                return RoutedReply.Local(intent, reply, ActionSummaryFor(result));
            }

            case LocalIntent.ClickLastTarget:
            {
                var target = _guidance.LastHighlighted;
                if (target is null)
                    return RoutedReply.Local(intent, "I don't have a highlighted target right now. Ask me \"where do I click to X\" first.");
                var (cx, cy) = target.Center;
                var result = await _executor.ExecuteAsync(
                    new ClickIntent((int)Math.Round(cx), (int)Math.Round(cy)),
                    cancellationToken).ConfigureAwait(false);
                _guidance.Clear();
                return RoutedReply.Local(intent,
                    result.Ok
                        ? $"Clicked **{target.Label}**."
                        : $"Couldn't click **{target.Label}**: {result.Message ?? result.Outcome.ToString()}.",
                    action: $"ClickIntent → {result.Outcome}");
            }

            case LocalIntent.OcrRegion:
                if (_captureRegion is null)
                    return RoutedReply.Local(intent, "Region capture isn't available in this session.");
                return RoutedReply.Streaming(intent, OcrCaptureStream(cancellationToken), "Started region capture");

            case LocalIntent.SummariseSelection:
                if (string.IsNullOrEmpty(context.SelectedText))
                    return RoutedReply.Local(intent, "I don't see any selected text to summarise.");
                // Hand off to the LLM — the context already carries the selection.
                return RoutedReply.PassThroughToLlm();

            case LocalIntent.CloseInteractionMenu:
                try { CloseInteractionMenuHook?.Invoke(); } catch { /* never fail the chat turn over this */ }
                // Empty inline reply — voice should feel silent on close.
                return RoutedReply.Local(intent, string.Empty, action: "menu closed");

            default:
                return RoutedReply.PassThroughToLlm();
        }
    }

    private static string StripGuidancePreamble(string message)
    {
        // "Where do I click to save this?" → "save this"
        var m = Regex.Replace(message, @"\b(where (do|should) (i|we) (click( to)?|find|press( for)?))\b\s*", "", RegexOptions.IgnoreCase);
        m = Regex.Replace(m, @"\?+\s*$", "");
        m = Regex.Replace(m, @"\bhighlight (the\s+)?", "", RegexOptions.IgnoreCase);
        return m.Trim();
    }

    private static string ActionSummaryFor(GuidanceResult result) =>
        result.Found ? $"Highlighted: {result.Best?.Label} ({result.Best?.Source})" : "no target";

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..max] + "…";

    private async IAsyncEnumerable<string> OcrCaptureStream(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        yield return "Drag to select a region…\n\n";
        string? text = null;
        string? error = null;
        try { text = await _captureRegion!(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { error = "_(cancelled)_"; }
        catch (Exception ex) { error = $"_(capture failed: {ex.Message})_"; }
        if (error is not null) { yield return error; yield break; }

        if (string.IsNullOrWhiteSpace(text))
        {
            yield return "_(no text detected in the captured region)_";
            yield break;
        }
        yield return "```\n";
        yield return text;
        yield return "\n```";
    }
}
