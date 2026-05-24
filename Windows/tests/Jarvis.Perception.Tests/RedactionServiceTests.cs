using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class RedactionServiceTests
{
    private static RedactionService Make(RedactionSettings? s = null) =>
        new(() => s ?? new RedactionSettings());

    [Fact]
    public void Vendor_tokens_are_redacted()
    {
        var r = Make();
        var (clean, report) = r.Redact("OpenAI key: sk-abc1234567890_DEF_xyz");
        clean.Should().NotContain("sk-abc1234567890_DEF_xyz");
        clean.Should().Contain("[REDACTED:vendor-token]");
        report.Categories.Should().ContainKey("secret.vendorToken");
    }

    [Fact]
    public void Github_pat_is_redacted()
    {
        var r = Make();
        var (clean, _) = r.Redact("token=ghp_AbCdEf0123456789AbCdEf012345");
        clean.Should().NotContain("ghp_");
    }

    [Fact]
    public void Bearer_header_is_redacted()
    {
        var r = Make();
        var (clean, report) = r.Redact("Authorization: Bearer eyJabcdefghij_klmnop1234567890");
        clean.Should().Contain("[REDACTED:bearer]");
        report.Categories.Should().ContainKey("secret.bearer");
    }

    [Fact]
    public void Credential_assignments_are_redacted()
    {
        var r = Make();
        var (clean, _) = r.Redact("password=hunter2 and api_key='deadbeef1234'");
        clean.Should().Contain("[REDACTED:credential]");
        clean.Should().NotContain("hunter2");
        clean.Should().NotContain("deadbeef1234");
    }

    [Fact]
    public void Generic_long_opaque_token_is_redacted()
    {
        var r = Make();
        var (clean, _) = r.Redact("Token: 9aF4eBcD0123456789aBcDeF0123456789aBcDeF");
        clean.Should().Contain("[REDACTED:token]");
    }

    [Fact]
    public void Emails_are_redacted_when_setting_on()
    {
        var r = Make();
        var (clean, _) = r.Redact("contact me at jane.doe@example.com please");
        clean.Should().Contain("[REDACTED:email]");
        clean.Should().NotContain("jane.doe@example.com");
    }

    [Fact]
    public void Emails_kept_when_setting_off()
    {
        var r = Make(new RedactionSettings { RedactEmails = false });
        var (clean, _) = r.Redact("jane@example.com");
        clean.Should().Be("jane@example.com");
    }

    [Fact]
    public void Phones_are_redacted_when_setting_on()
    {
        var r = Make();
        var (clean, _) = r.Redact("call me on +44 20 7946 0958 sometime");
        clean.Should().Contain("[REDACTED:phone]");
    }

    [Fact]
    public void File_paths_are_redacted_when_setting_on()
    {
        var r = Make(new RedactionSettings { RedactFilePaths = true });
        var (clean, _) = r.Redact(@"opened C:\Users\Chris\secret.txt and /Users/alice/.ssh/id_rsa");
        clean.Should().Contain("[REDACTED:path]");
        clean.Should().NotContain("Chris");
    }

    [Fact]
    public void Url_token_params_are_redacted()
    {
        var r = Make();
        var (clean, _) = r.Redact("https://x/api?token=abcdef1234&user=jane");
        clean.Should().Contain("[REDACTED:url-token]");
        clean.Should().Contain("user=jane"); // non-secret query params survive
    }

    [Fact]
    public void Disabled_redactor_returns_input_unchanged()
    {
        var r = Make(new RedactionSettings { Enabled = false });
        var input = "sk-abcdef1234567890 jane@example.com";
        var (clean, report) = r.Redact(input);
        clean.Should().Be(input);
        report.Replacements.Should().Be(0);
    }

    [Fact]
    public void Null_input_returns_empty()
    {
        var r = Make();
        var (clean, report) = r.Redact(null);
        clean.Should().BeEmpty();
        report.Replacements.Should().Be(0);
    }
}
