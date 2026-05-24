using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class DailyQuotaGuardTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"quota-{Guid.NewGuid():N}.json");

    private DailyQuotaGuard Make(QuotaSettings? s = null) => new(() => s ?? new QuotaSettings(), _path);

    [Fact]
    public void Local_providers_are_exempt_by_default()
    {
        var g = Make();
        for (var i = 0; i < 1000; i++)
        {
            var r = g.Reserve(LlmProviderType.Ollama, 5000);
            r.Allowed.Should().BeTrue();
        }
    }

    [Fact]
    public void Cloud_providers_count_against_request_cap()
    {
        var g = Make(new QuotaSettings { MaxRequestsPerDay = 3, MaxApproxCharsPerDay = 100_000 });
        g.Reserve(LlmProviderType.OpenAi, 100).Allowed.Should().BeTrue();
        g.Reserve(LlmProviderType.OpenAi, 100).Allowed.Should().BeTrue();
        g.Reserve(LlmProviderType.OpenAi, 100).Allowed.Should().BeTrue();
        var blocked = g.Reserve(LlmProviderType.OpenAi, 100);
        blocked.Allowed.Should().BeFalse();
        blocked.Reason.Should().Contain("request cap");
    }

    [Fact]
    public void Cloud_providers_count_against_char_cap()
    {
        var g = Make(new QuotaSettings { MaxRequestsPerDay = 100, MaxApproxCharsPerDay = 200 });
        g.Reserve(LlmProviderType.OpenAi, 150).Allowed.Should().BeTrue();
        var blocked = g.Reserve(LlmProviderType.OpenAi, 100);
        blocked.Allowed.Should().BeFalse();
        blocked.Reason.Should().Contain("char cap");
    }

    [Fact]
    public void Disabled_quota_allows_everything()
    {
        var g = Make(new QuotaSettings { Enabled = false, MaxRequestsPerDay = 1 });
        g.Reserve(LlmProviderType.OpenAi, 1_000_000).Allowed.Should().BeTrue();
        g.Reserve(LlmProviderType.OpenAi, 1_000_000).Allowed.Should().BeTrue();
    }

    [Fact]
    public void Counter_persists_across_instances()
    {
        var g1 = Make();
        g1.Reserve(LlmProviderType.OpenAi, 100).Allowed.Should().BeTrue();
        var status1 = g1.Status;

        var g2 = Make();
        g2.Status.RequestsToday.Should().Be(status1.RequestsToday);
        g2.Status.CharsToday.Should().Be(status1.CharsToday);
    }

    [Fact]
    public void Near_and_at_limit_flags_are_set()
    {
        var g = Make(new QuotaSettings { MaxRequestsPerDay = 10, MaxApproxCharsPerDay = 1_000_000 });
        for (var i = 0; i < 8; i++) g.Reserve(LlmProviderType.OpenAi, 1);
        g.Status.NearLimit.Should().BeTrue();
        g.Status.AtLimit.Should().BeFalse();
        for (var i = 0; i < 2; i++) g.Reserve(LlmProviderType.OpenAi, 1);
        g.Status.AtLimit.Should().BeTrue();
    }

    public void Dispose() { try { File.Delete(_path); } catch { } }
}
