using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Conversation;
using Jarvis.Core.Guidance;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class CloseMenuIntentTests
{
    private static LocalIntentRouter Build() => new(
        guidance: new FakeGuidance(),
        executor: new FakeExecutor(),
        highlighter: new FakeHighlighter());

    [Theory]
    [InlineData("close menu")]
    [InlineData("close the menu")]
    [InlineData("hide menu")]
    [InlineData("dismiss menu")]
    [InlineData("close menu.")]
    public void Phrases_classify_as_CloseInteractionMenu(string phrase)
    {
        Build().Classify(phrase).Should().Be(LocalIntent.CloseInteractionMenu);
    }

    [Fact]
    public async Task Route_invokes_hook()
    {
        var calls = 0;
        var router = Build();
        router.CloseInteractionMenuHook = () => calls++;
        await router.RouteAsync(LocalIntent.CloseInteractionMenu, "close menu", ConversationContext.Empty, default);
        calls.Should().Be(1);
    }

    [Fact]
    public async Task Missing_hook_is_safe_no_throw()
    {
        var router = Build();
        // hook left null on purpose
        var act = async () => await router.RouteAsync(LocalIntent.CloseInteractionMenu, "close menu", ConversationContext.Empty, default);
        await act.Should().NotThrowAsync();
    }

    [Fact]
    public void Random_message_is_not_misclassified()
    {
        var router = Build();
        router.Classify("what's the weather").Should().NotBe(LocalIntent.CloseInteractionMenu);
        router.Classify("close the file").Should().NotBe(LocalIntent.CloseInteractionMenu);
    }

    private sealed class FakeGuidance : IGuidanceService
    {
        public UiTarget? LastHighlighted => null;
        public GuidanceDiagnostics? LastDiagnostics => null;
        public Task<GuidanceResult> AskAsync(string query, CancellationToken cancellationToken = default) =>
            Task.FromResult(new GuidanceResult(query, null, Array.Empty<RankedCandidate>(), "noop", null, LowConfidence: true));
        public void Clear() { }
    }
    private sealed class FakeExecutor : IAutomationExecutor
    {
        public AutomationPlan DryRun(AutomationIntent intent) =>
            new("noop", Array.Empty<string>(), null, null, new SafetyDecision(SafetyTier.Approve, "test"));
        public Task<AutomationResult> ExecuteAsync(AutomationIntent intent, CancellationToken cancellationToken = default) =>
            Task.FromResult(new AutomationResult(intent, DryRun(intent),
                AutomationOutcome.Succeeded, null, null, DateTimeOffset.UtcNow, TimeSpan.Zero));
    }
    private sealed class FakeHighlighter : IHighlightRenderer
    {
        public Task ShowAsync(int x, int y, int w, int h, string? label, TimeSpan duration, CancellationToken cancellationToken = default)
            => Task.CompletedTask;
    }
}
