using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Conversation;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class LocalIntentRouterTests
{
    [Theory]
    [InlineData("Where do I click to save this?", LocalIntent.WhereDoIClick)]
    [InlineData("where do I click", LocalIntent.WhereDoIClick)]
    [InlineData("where to click for continue", LocalIntent.WhereDoIClick)]
    [InlineData("click it", LocalIntent.ClickLastTarget)]
    [InlineData("Click it.", LocalIntent.ClickLastTarget)]
    [InlineData("do it", LocalIntent.ClickLastTarget)]
    [InlineData("press it now", LocalIntent.ClickLastTarget)]
    [InlineData("highlight the save button", LocalIntent.HighlightTarget)]
    [InlineData("what app am I in", LocalIntent.WhatApp)]
    [InlineData("which app", LocalIntent.WhatApp)]
    [InlineData("what page is this", LocalIntent.WhatPage)]
    [InlineData("what url", LocalIntent.WhatPage)]
    [InlineData("what did I select", LocalIntent.WhatSelection)]
    [InlineData("show me my selection", LocalIntent.WhatSelection)]
    [InlineData("what's on my clipboard", LocalIntent.WhatClipboard)]
    [InlineData("read my clipboard", LocalIntent.WhatClipboard)]
    [InlineData("summarize the selection", LocalIntent.SummariseSelection)]
    [InlineData("summarise selected text", LocalIntent.SummariseSelection)]
    [InlineData("ocr this", LocalIntent.OcrRegion)]
    [InlineData("what does this say", LocalIntent.OcrRegion)]
    [InlineData("How do I refactor this method?", LocalIntent.Unknown)]
    [InlineData("Tell me a joke", LocalIntent.Unknown)]
    public void Classifies_phrases(string input, LocalIntent expected)
    {
        var router = MakeRouter();
        router.Classify(input).Should().Be(expected);
    }

    [Fact]
    public async Task WhatApp_reads_context_without_side_effects()
    {
        var (router, deps) = MakeRouterWithDeps();
        var ctx = MakeContext(foregroundApp: "Code", title: "main.cs - VS Code");
        var reply = await router.RouteAsync(LocalIntent.WhatApp, "what app am I in?", ctx, default);
        reply.InlineReply.Should().Contain("Code");
        reply.RequiresLlm.Should().BeFalse();
        deps.ExecutorCalls.Should().Be(0);
    }

    [Fact]
    public async Task WhatSelection_returns_selected_text()
    {
        var (router, _) = MakeRouterWithDeps();
        var ctx = MakeContext(selectedText: "var x = 42;", selectedType: SemanticContentType.Code);
        var reply = await router.RouteAsync(LocalIntent.WhatSelection, "what did I select", ctx, default);
        reply.InlineReply.Should().Contain("var x = 42;");
        reply.InlineReply.Should().Contain("Code");
    }

    [Fact]
    public async Task ClickLastTarget_uses_executor_when_target_exists()
    {
        var target = new UiTarget("Save", "button", new Rect(100, 200, 180, 224), 0.8,
            TargetSource.UiAutomation, ActionHint: "click", Enabled: true);
        var (router, deps) = MakeRouterWithDeps(lastHighlighted: target);
        var reply = await router.RouteAsync(LocalIntent.ClickLastTarget, "click it", ConversationContext.Empty, default);
        deps.ExecutorCalls.Should().Be(1);
        deps.LastIntent.Should().BeOfType<ClickIntent>();
        reply.InlineReply.Should().Contain("Save");
    }

    [Fact]
    public async Task ClickLastTarget_refuses_when_no_target()
    {
        var (router, deps) = MakeRouterWithDeps(lastHighlighted: null);
        var reply = await router.RouteAsync(LocalIntent.ClickLastTarget, "click it", ConversationContext.Empty, default);
        deps.ExecutorCalls.Should().Be(0);
        reply.InlineReply.Should().Contain("don't have a highlighted target");
    }

    [Fact]
    public async Task SummariseSelection_passes_through_to_llm_when_selection_present()
    {
        var (router, _) = MakeRouterWithDeps();
        var ctx = MakeContext(selectedText: "some prose here");
        var reply = await router.RouteAsync(LocalIntent.SummariseSelection, "summarise the selection", ctx, default);
        reply.RequiresLlm.Should().BeTrue();
    }

    [Fact]
    public async Task SummariseSelection_does_not_pass_through_when_no_selection()
    {
        var (router, _) = MakeRouterWithDeps();
        var reply = await router.RouteAsync(LocalIntent.SummariseSelection, "summarise the selection", ConversationContext.Empty, default);
        reply.RequiresLlm.Should().BeFalse();
        reply.InlineReply.Should().Contain("selected text");
    }

    [Fact]
    public async Task WhereDoIClick_calls_guidance_and_returns_explanation()
    {
        var (router, deps) = MakeRouterWithDeps();
        deps.NextGuidance = new GuidanceResult(
            Query: "save",
            Best: new UiTarget("Save", "button", new Rect(0, 0, 80, 24), 0.8, TargetSource.UiAutomation, ActionHint: "click", Enabled: true),
            Candidates: Array.Empty<RankedCandidate>(),
            Explanation: "This looks like the Save button.",
            SuggestedClick: new ClickIntent(40, 12),
            LowConfidence: false);
        var reply = await router.RouteAsync(LocalIntent.WhereDoIClick, "where do I click to save?", ConversationContext.Empty, default);
        deps.GuidanceCalls.Should().Be(1);
        reply.InlineReply.Should().Contain("Save button");
        reply.InlineReply.Should().Contain("click it"); // hint
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static LocalIntentRouter MakeRouter() => MakeRouterWithDeps().Router;
    private static (LocalIntentRouter Router, FakeDeps Deps) MakeRouterWithDeps(UiTarget? lastHighlighted = null)
    {
        var deps = new FakeDeps { LastTarget = lastHighlighted };
        var router = new LocalIntentRouter(deps, deps, deps);
        return (router, deps);
    }

    private static ConversationContext MakeContext(
        string? foregroundApp = null, string? title = null,
        string? selectedText = null, SemanticContentType selectedType = SemanticContentType.Unknown,
        string? clipboard = null) =>
        new(DateTimeOffset.UtcNow, foregroundApp, title, WorkflowCategory.Unknown,
            selectedText, selectedType, clipboard, SemanticContentType.Unknown,
            null, null, null, null, "h");

    private sealed class FakeDeps : IGuidanceService, IAutomationExecutor, IHighlightRenderer
    {
        public UiTarget? LastTarget;
        public UiTarget? LastHighlighted => LastTarget;
        public GuidanceDiagnostics? LastDiagnostics => null;
        public int GuidanceCalls;
        public int ExecutorCalls;
        public AutomationIntent? LastIntent;
        public GuidanceResult? NextGuidance;

        public Task<GuidanceResult> AskAsync(string query, CancellationToken cancellationToken = default)
        {
            GuidanceCalls++;
            return Task.FromResult(NextGuidance ?? new GuidanceResult(query, null, Array.Empty<RankedCandidate>(),
                "no targets", null, LowConfidence: true));
        }
        public void Clear() { LastTarget = null; }

        public AutomationPlan DryRun(AutomationIntent intent) =>
            new("dry", Array.Empty<string>(), null, null, new SafetyDecision(SafetyTier.Approve, "test"));
        public Task<AutomationResult> ExecuteAsync(AutomationIntent intent, CancellationToken cancellationToken = default)
        {
            ExecutorCalls++;
            LastIntent = intent;
            return Task.FromResult(new AutomationResult(intent, DryRun(intent),
                AutomationOutcome.Succeeded, null, null, DateTimeOffset.UtcNow, TimeSpan.FromMilliseconds(1)));
        }

        public Task ShowAsync(int x, int y, int w, int h, string? label, TimeSpan duration, CancellationToken cancellationToken = default) =>
            Task.CompletedTask;
    }
}
