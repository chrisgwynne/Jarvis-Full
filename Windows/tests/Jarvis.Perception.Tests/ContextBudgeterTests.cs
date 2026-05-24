using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Perception;
using Jarvis.Core.Settings;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class ContextBudgeterTests
{
    private static ContextBudgeter Build(RedactionSettings? r = null, LlmSettings? l = null)
    {
        r ??= new RedactionSettings();
        l ??= new LlmSettings();
        return new ContextBudgeter(new RedactionService(() => r), () => r, () => l);
    }

    [Fact]
    public void Truncates_selected_text_to_max()
    {
        var b = Build(new RedactionSettings { MaxSelectedTextChars = 50 });
        var ctx = ConversationContext.Empty with { SelectedText = new string('a', 1000), SnapshotHash = "h" };
        var (compact, _) = b.Budget(ctx);
        compact.SelectedText!.Length.Should().BeLessThanOrEqualTo(51); // 50 + ellipsis
    }

    [Fact]
    public void Truncates_clipboard_to_max()
    {
        var b = Build(new RedactionSettings { MaxClipboardChars = 20 });
        var ctx = ConversationContext.Empty with { ClipboardSummary = new string('x', 500), SnapshotHash = "h" };
        var (compact, _) = b.Budget(ctx);
        compact.ClipboardSummary!.Length.Should().BeLessThanOrEqualTo(21);
    }

    [Fact]
    public void Redacts_secret_in_selection()
    {
        var b = Build();
        var ctx = ConversationContext.Empty with
        {
            SelectedText = "OPENAI_API_KEY=sk-abcdef1234567890abcdef1234567890",
            SnapshotHash = "h"
        };
        var (compact, report) = b.Budget(ctx);
        compact.SelectedText.Should().NotContain("sk-abcdef");
        report.Replacements.Should().BeGreaterThan(0);
    }

    [Fact]
    public void Context_disabled_returns_empty_compact()
    {
        var b = Build(null, new LlmSettings { ContextInjectionEnabled = false });
        var ctx = ConversationContext.Empty with
        {
            ForegroundApp = "Code",
            SelectedText = "secret text",
            SnapshotHash = "h"
        };
        var (compact, _) = b.Budget(ctx);
        compact.ForegroundApp.Should().BeNull();
        compact.SelectedText.Should().BeNull();
        compact.SnapshotHash.Should().Be("h"); // hash is the only thing we keep
    }

    [Fact]
    public void Browser_url_query_secrets_are_redacted()
    {
        var b = Build();
        var browser = new BrowserContextSnapshot(DateTimeOffset.UtcNow,
            "chrome", "https://x/api?token=abcdef123456&user=jane",
            "x", "X", null, null, false);
        var ctx = ConversationContext.Empty with { Browser = browser, SnapshotHash = "h" };
        var (compact, _) = b.Budget(ctx);
        compact.Browser!.Url.Should().Contain("[REDACTED:url-token]");
        compact.Browser.Url.Should().Contain("user=jane");
    }

    [Fact]
    public void Report_aggregates_counts_across_fields()
    {
        var b = Build();
        var ctx = ConversationContext.Empty with
        {
            SelectedText = "a@b.com",
            ClipboardSummary = "c@d.com",
            RecentOcrSummary = "e@f.com",
            SnapshotHash = "h"
        };
        var (_, report) = b.Budget(ctx);
        report.Replacements.Should().BeGreaterThanOrEqualTo(3);
        report.Categories.Should().ContainKey("pii.email");
    }
}
