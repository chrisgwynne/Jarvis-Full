using Jarvis.Core.Conversation;
using Jarvis.Core.Perception;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Trims and redacts a <see cref="ConversationContext"/> before sending it to a cloud
/// provider. Caller decides whether to use the compact version (LLM) or the original
/// (local intent reads). Aggregates a per-call <see cref="RedactionReport"/> so the
/// diagnostics layer can show the user "10 things were redacted".
/// </summary>
public sealed class ContextBudgeter : IContextBudgeter
{
    private readonly IRedactor _redactor;
    private readonly Func<RedactionSettings> _settings;
    private readonly Func<LlmSettings> _llmSettings;

    public ContextBudgeter(IRedactor redactor, Func<RedactionSettings> settings, Func<LlmSettings> llmSettings)
    {
        _redactor = redactor;
        _settings = settings;
        _llmSettings = llmSettings;
    }

    public (ConversationContext Compact, RedactionReport Report) Budget(ConversationContext context)
    {
        // Respect "context injection disabled" by returning the empty context.
        if (!_llmSettings().ContextInjectionEnabled)
            return (ConversationContext.Empty with { SnapshotHash = context.SnapshotHash }, new RedactionReport(0, new Dictionary<string, int>()));

        var cfg = _settings();
        var totalHits = new Dictionary<string, int>();
        int total = 0;

        string? Run(string? value, int max)
        {
            if (string.IsNullOrEmpty(value)) return null;
            var truncated = value.Length <= max ? value : value[..max] + "…";
            var (clean, report) = _redactor.Redact(truncated);
            total += report.Replacements;
            foreach (var (k, v) in report.Categories)
                totalHits[k] = totalHits.TryGetValue(k, out var prev) ? prev + v : v;
            return clean;
        }

        var selection = Run(context.SelectedText, cfg.MaxSelectedTextChars);
        var clipboard = Run(context.ClipboardSummary, cfg.MaxClipboardChars);
        var ocr       = Run(context.RecentOcrSummary, cfg.MaxOcrChars);

        // Browser snapshot: redact URL token params + truncate title.
        BrowserContextSnapshot? browser = null;
        if (context.Browser is { } b)
        {
            var (cleanUrl, urlReport) = _redactor.Redact(b.Url ?? "");
            total += urlReport.Replacements;
            foreach (var (k, v) in urlReport.Categories)
                totalHits[k] = totalHits.TryGetValue(k, out var prev) ? prev + v : v;

            browser = b with
            {
                Url = string.IsNullOrEmpty(cleanUrl) ? b.Url : cleanUrl,
                Title = Truncate(b.Title, 240),
                SelectedText = Run(b.SelectedText, cfg.MaxSelectedTextChars)
            };
        }

        var compact = context with
        {
            ForegroundWindowTitle = Truncate(context.ForegroundWindowTitle, 240),
            SelectedText = selection,
            ClipboardSummary = clipboard,
            RecentOcrSummary = ocr,
            Browser = browser
        };
        return (compact, new RedactionReport(total, totalHits));
    }

    private static string? Truncate(string? s, int max) =>
        string.IsNullOrEmpty(s) ? s : s.Length <= max ? s : s[..max] + "…";
}
