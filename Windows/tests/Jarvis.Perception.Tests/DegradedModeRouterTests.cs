using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class DegradedModeRouterTests
{
    [Fact]
    public void When_bridge_connected_routes_to_sidecar()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var sidecar = new SidecarLlmClient(bridge);
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local, () => new SidecarSettings { OfflineDegradedModeEnabled = true });
        // Sidecar is configured because the bridge says Connected.
        router.IsConfigured.Should().BeTrue();
    }

    [Fact]
    public async Task When_bridge_down_and_degraded_enabled_routes_to_local()
    {
        var bridge = new FakeBridge(BridgeState.Degraded);
        var sidecar = new SidecarLlmClient(bridge);
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local, () => new SidecarSettings { OfflineDegradedModeEnabled = true });
        var chunks = await Collect(router.StreamAsync(BuildRequest(), default));
        string.Concat(chunks).Should().Contain("LOCAL");
    }

    [Fact]
    public async Task When_bridge_down_and_degraded_disabled_returns_placeholder()
    {
        var bridge = new FakeBridge(BridgeState.Degraded);
        var sidecar = new SidecarLlmClient(bridge);
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local, () => new SidecarSettings { OfflineDegradedModeEnabled = false });
        var chunks = await Collect(router.StreamAsync(BuildRequest(), default));
        string.Concat(chunks).Should().Contain("Mac bridge is down");
        string.Concat(chunks).Should().NotContain("LOCAL");
    }

    private static LlmRequest BuildRequest() => new(
        SystemPrompt: "be terse",
        History: Array.Empty<ChatMessage>(),
        UserMessage: "hello",
        Context: ConversationContext.Empty);

    private static async Task<List<string>> Collect(IAsyncEnumerable<string> stream)
    {
        var list = new List<string>();
        await foreach (var s in stream) list.Add(s);
        return list;
    }

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public BridgeStatus Status { get; }
        public FakeBridge(BridgeState s) { Status = new BridgeStatus(s, DateTimeOffset.UtcNow, 0, null, null); }
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived { add { } remove { } }
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default) => Task.FromResult(true);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class MarkingLocalClient : ILlmClient
    {
        private readonly string _tag;
        public MarkingLocalClient(string tag) { _tag = tag; }
        public bool IsConfigured => true;
        public async IAsyncEnumerable<string> StreamAsync(LlmRequest request, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            await Task.CompletedTask;
            yield return _tag + " ";
            yield return "reply";
        }
    }
}
