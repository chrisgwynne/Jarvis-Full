using FluentAssertions;
using Jarvis.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class TokenBucketRateLimiterTests
{
    [Fact]
    public void Allows_under_per_kind_capacity()
    {
        var rl = new TokenBucketRateLimiter();
        for (var i = 0; i < 8; i++) rl.TryAcquire("keyboard.type").Allowed.Should().BeTrue();
    }

    [Fact]
    public void Denies_when_per_kind_capacity_exceeded()
    {
        var rl = new TokenBucketRateLimiter();
        for (var i = 0; i < 8; i++) rl.TryAcquire("keyboard.type");
        var d = rl.TryAcquire("keyboard.type");
        d.Allowed.Should().BeFalse();
        d.Reason.Should().Contain("keyboard.type");
    }

    [Fact]
    public void Denies_when_global_capacity_exceeded()
    {
        var rl = new TokenBucketRateLimiter(global: (3, TimeSpan.FromMinutes(1)));
        rl.TryAcquire("window.focus").Allowed.Should().BeTrue();
        rl.TryAcquire("window.focus").Allowed.Should().BeTrue();
        rl.TryAcquire("window.focus").Allowed.Should().BeTrue();
        var d = rl.TryAcquire("window.focus");
        d.Allowed.Should().BeFalse();
        d.Reason.Should().Contain("global");
    }

    [Fact]
    public void Per_kind_buckets_are_independent()
    {
        var rl = new TokenBucketRateLimiter();
        for (var i = 0; i < 8; i++) rl.TryAcquire("keyboard.type"); // drain type
        // click bucket should still have tokens
        rl.TryAcquire("mouse.click").Allowed.Should().BeTrue();
    }

    [Fact]
    public void Unknown_kinds_only_consume_global()
    {
        var rl = new TokenBucketRateLimiter(global: (5, TimeSpan.FromMinutes(1)));
        for (var i = 0; i < 5; i++) rl.TryAcquire("custom.kind").Allowed.Should().BeTrue();
        rl.TryAcquire("custom.kind").Allowed.Should().BeFalse();
    }
}
