using System.Runtime.CompilerServices;
using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Core.Conversation;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class ConversationServiceTests
{
    [Fact]
    public async Task Local_intent_does_not_invoke_llm()
    {
        var llm = new RecordingLlm();
        var svc = Build(llm, new StaticRouter(LocalIntent.WhatApp, "You're in Code."));
        var turn = await svc.SendAsync("what app am I in");
        turn.RoutedIntent.Should().Be(LocalIntent.WhatApp);
        turn.Diagnostics.LlmUsed.Should().BeFalse();
        llm.Calls.Should().Be(0);
        turn.Assistant.Content.Should().Contain("Code");
    }

    [Fact]
    public async Task Unknown_intent_falls_through_to_llm()
    {
        var llm = new RecordingLlm("hi from the model");
        var svc = Build(llm, new StaticRouter(LocalIntent.Unknown, null, passThrough: true));
        var turn = await svc.SendAsync("tell me a joke");
        turn.RoutedIntent.Should().Be(LocalIntent.Unknown);
        turn.Diagnostics.LlmUsed.Should().BeTrue();
        llm.Calls.Should().Be(1);
        turn.Assistant.Content.Should().Contain("hi from the model");
    }

    [Fact]
    public async Task Context_snapshot_hash_is_carried_into_diagnostics()
    {
        var llm = new RecordingLlm();
        var svc = Build(llm, new StaticRouter(LocalIntent.WhatApp, "ok"), "abc123");
        var turn = await svc.SendAsync("what app");
        turn.Diagnostics.SnapshotHash.Should().Be("abc123");
    }

    [Fact]
    public async Task Streaming_chunks_fire_in_order_and_concatenate()
    {
        var llm = new RecordingLlm("Hello ", "world", "!");
        var svc = Build(llm, new StaticRouter(LocalIntent.Unknown, null, passThrough: true));
        var collected = new List<string>();
        svc.StreamChunk += (_, m) => collected.Add(m.Content);
        var turn = await svc.SendAsync("anything");
        collected.Should().Equal("Hello ", "world", "!");
        turn.Assistant.Content.Should().Be("Hello world!");
    }

    [Fact]
    public async Task Cancellation_yields_cancelled_marker_in_assistant_message()
    {
        var llm = new RecordingLlm(new[] { "a", "b", "c" }, perChunkDelay: TimeSpan.FromMilliseconds(60));
        var svc = Build(llm, new StaticRouter(LocalIntent.Unknown, null, passThrough: true));
        var cts = new CancellationTokenSource();
        cts.CancelAfter(50);
        var turn = await svc.SendAsync("stream me", cts.Token);
        turn.Assistant.Content.Should().Contain("(cancelled)");
    }

    [Fact]
    public async Task History_records_user_then_assistant()
    {
        var llm = new RecordingLlm();
        var svc = Build(llm, new StaticRouter(LocalIntent.WhatApp, "ok"));
        await svc.SendAsync("what app");
        svc.History.Should().HaveCount(2);
        svc.History[0].Role.Should().Be(ChatRole.User);
        svc.History[1].Role.Should().Be(ChatRole.Assistant);
    }

    [Fact]
    public async Task Clear_drops_history()
    {
        var svc = Build(new RecordingLlm(), new StaticRouter(LocalIntent.WhatApp, "ok"));
        await svc.SendAsync("hi");
        svc.History.Should().HaveCount(2);
        svc.Clear();
        svc.History.Should().BeEmpty();
    }

    private static ConversationService Build(ILlmClient llm, ILocalIntentRouter router, string snapshotHash = "test-hash")
        => new(new StaticContextBuilder(snapshotHash), router, llm);

    private sealed class StaticContextBuilder : IConversationContextBuilder
    {
        private readonly string _hash;
        public StaticContextBuilder(string hash) => _hash = hash;
        public ConversationContext Build() => ConversationContext.Empty with { SnapshotHash = _hash, ForegroundApp = "Code" };
    }

    private sealed class StaticRouter : ILocalIntentRouter
    {
        private readonly LocalIntent _intent;
        private readonly string? _inline;
        private readonly bool _passThrough;
        public StaticRouter(LocalIntent intent, string? inline, bool passThrough = false)
        { _intent = intent; _inline = inline; _passThrough = passThrough; }
        public LocalIntent Classify(string userMessage) => _intent;
        public Task<RoutedReply> RouteAsync(LocalIntent intent, string userMessage, ConversationContext context, CancellationToken cancellationToken)
            => Task.FromResult(_passThrough ? RoutedReply.PassThroughToLlm() : RoutedReply.Local(intent, _inline ?? "ok"));
    }

    private sealed class RecordingLlm : ILlmClient
    {
        private readonly string[] _chunks;
        private readonly TimeSpan _delay;
        public int Calls;
        public RecordingLlm(params string[] chunks) : this(chunks, TimeSpan.Zero) { }
        public RecordingLlm(string[] chunks, TimeSpan perChunkDelay) { _chunks = chunks; _delay = perChunkDelay; }
        public bool IsConfigured => true;
        public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            Calls++;
            foreach (var c in _chunks)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (_delay > TimeSpan.Zero) await Task.Delay(_delay, cancellationToken);
                yield return c;
            }
        }
    }
}
