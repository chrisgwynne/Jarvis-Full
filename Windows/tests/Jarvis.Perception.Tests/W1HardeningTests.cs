using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

// ─────────────────────────────────────────────────────────────────────────────
// W1 Sprint — Mac-Brain Contract Hardening
//
// These tests prove the four fundamental sidecar invariants:
//   1. Local LLM is blocked whenever the Mac bridge is Connected.
//   2. Local LLM is only reachable when bridge is down AND degraded mode is enabled.
//   3. RemoteOrchestrationCoordinator never fires events from local state alone.
//   4. PrivacyMode suppresses transcripts at both the echo-suppressor layer and
//      the coordinator layer independently.
// ─────────────────────────────────────────────────────────────────────────────

public class W1HardeningTests
{
    // ── Task 1: LocalLlmFallbackPolicy ────────────────────────────────────────

    [Theory]
    [InlineData(BridgeState.Connected,    true,  false)] // connected  → never local
    [InlineData(BridgeState.Connected,    false, false)] // connected  → never local
    [InlineData(BridgeState.Reconnecting, true,  true)]  // offline + enabled → local ok
    [InlineData(BridgeState.Degraded,     true,  true)]  // degraded + enabled → local ok
    [InlineData(BridgeState.Degraded,     false, false)] // degraded + disabled → blocked
    [InlineData(BridgeState.Disabled,     true,  true)]  // disabled + enabled → local ok
    [InlineData(BridgeState.Disabled,     false, false)] // disabled + disabled → blocked
    public void Policy_blocks_local_llm_when_bridge_connected(
        BridgeState state, bool degradedEnabled, bool expected)
    {
        LocalLlmFallbackPolicy.CanUseLocalLlm(state, degradedEnabled).Should().Be(expected);
    }

    // ── Task 1: DegradedModeRouter uses the policy ─────────────────────────────

    [Fact]
    public async Task DegradedRouter_bridge_connected_local_provider_never_called()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var sidecar = new SidecarLlmClient(bridge); // IsConfigured = true (bridge Connected)
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local,
            () => new SidecarSettings { OfflineDegradedModeEnabled = true });

        // Cancel quickly — the sidecar client blocks waiting for Mac reply frames.
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        var chunks = new List<string>();
        try
        {
            await foreach (var c in router.StreamAsync(MakeRequest(), cts.Token).ConfigureAwait(false))
                chunks.Add(c);
        }
        catch (OperationCanceledException) { /* expected — no Mac reply arrives in test */ }

        local.WasCalled.Should().BeFalse("local LLM must never be reached while Mac bridge is Connected");
        string.Concat(chunks).Should().NotContain("LOCAL");
    }

    [Fact]
    public async Task DegradedRouter_degraded_and_enabled_reaches_local()
    {
        var bridge = new FakeBridge(BridgeState.Degraded);
        var sidecar = new SidecarLlmClient(bridge); // IsConfigured = false (bridge not Connected)
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local,
            () => new SidecarSettings { OfflineDegradedModeEnabled = true });

        var chunks = await CollectAsync(router.StreamAsync(MakeRequest(), default));
        local.WasCalled.Should().BeTrue();
        string.Concat(chunks).Should().Contain("LOCAL");
    }

    [Fact]
    public async Task DegradedRouter_degraded_and_disabled_returns_placeholder_not_local()
    {
        var bridge = new FakeBridge(BridgeState.Degraded);
        var sidecar = new SidecarLlmClient(bridge);
        var local = new MarkingLocalClient("LOCAL");
        var router = new DegradedModeRouter(bridge, sidecar, local,
            () => new SidecarSettings { OfflineDegradedModeEnabled = false });

        var chunks = await CollectAsync(router.StreamAsync(MakeRequest(), default));
        local.WasCalled.Should().BeFalse();
        string.Concat(chunks).Should().Contain("Mac bridge is down");
    }

    // ── Task 5: RemoteOrchestrationCoordinator — no local-state triggers ──────

    [Fact]
    public void Orchestration_coordinator_emits_no_events_without_inbound_frame()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var coord = new RemoteOrchestrationCoordinator(bridge);
        var fired = 0;
        coord.Attach();
        coord.SpeakRequested  += (_, _) => fired++;
        coord.SilenceRequested += (_, _) => fired++;
        coord.ProactiveReceived += (_, _) => fired++;

        // No frames delivered — no events should fire.
        fired.Should().Be(0, "Windows must not generate proactive or orchestration events from local state");
    }

    [Fact]
    public void Orchestration_coordinator_requires_mac_frame_to_fire_speak()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        string? spoken = null;
        coord.SpeakRequested += (_, text) => spoken = text;

        // Without a frame, nothing fires.
        spoken.Should().BeNull();

        // Only after a Mac frame does the event fire.
        bridge.Receive(new SidecarFrame { Type = SidecarFrameTypes.OrchestrateSpeak, Text = "hello world" });
        spoken.Should().Be("hello world");
    }

    [Fact]
    public void Orchestration_coordinator_requires_mac_frame_to_fire_proactive()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var coord = new RemoteOrchestrationCoordinator(bridge);
        coord.Attach();
        ProactiveNotice? notice = null;
        coord.ProactiveReceived += (_, n) => notice = n;

        notice.Should().BeNull();

        bridge.Receive(new SidecarFrame
        {
            Type = SidecarFrameTypes.ProactiveNotify,
            Reason = "Build failed",
            Text = "2 tests broke",
            Source = "ci",
            At = DateTimeOffset.UtcNow
        });
        notice.Should().NotBeNull();
        notice!.Title.Should().Be("Build failed");
    }

    // ── Task 9: PrivacyMode — echo suppressor initialises from settings ────────

    [Fact]
    public void EchoSuppressor_privacy_mode_active_on_construction_when_settings_say_so()
    {
        var coord = new EchoSuppressionCoordinator(() => new SidecarSettings { PrivacyMode = true });
        // Without ever calling SetPrivacyMode, suppression should already be active.
        coord.ShouldSuppress("anything at all").Should().Be(SuppressionReason.PrivacyMode);
    }

    [Fact]
    public void EchoSuppressor_privacy_mode_off_by_default_when_settings_say_so()
    {
        var coord = new EchoSuppressionCoordinator(() => new SidecarSettings { PrivacyMode = false });
        // No speech active → normal text should pass through (not PrivacyMode).
        var reason = coord.ShouldSuppress("hello");
        reason.Should().NotBe(SuppressionReason.PrivacyMode);
    }

    // ── Task 9: PrivacyMode — transcript coordinator suppresses both layers ────

    [Fact]
    public void TranscriptCoordinator_suppresses_partial_when_privacy_mode_on()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { PrivacyMode = true });
        var diag = new AudioDiagnostics();
        var coord = new PartialTranscriptCoordinator(bridge, echo, diag,
            settings: () => new SidecarSettings { PrivacyMode = true });

        var provider = new FakeSpeechProvider();
        coord.Attach(provider);

        provider.EmitPartial("secret transcript");

        coord.SuppressedPartials.Should().Be(1, "partial must be suppressed in privacy mode");
        coord.PartialsSent.Should().Be(0, "nothing should reach the bridge in privacy mode");
        bridge.SentFrames.Should().BeEmpty();
    }

    [Fact]
    public void TranscriptCoordinator_suppresses_final_when_privacy_mode_on()
    {
        var bridge = new FakeBridge(BridgeState.Connected);
        var echo = new EchoSuppressionCoordinator(() => new SidecarSettings { PrivacyMode = true });
        var diag = new AudioDiagnostics();
        var coord = new PartialTranscriptCoordinator(bridge, echo, diag,
            settings: () => new SidecarSettings { PrivacyMode = true });

        var provider = new FakeSpeechProvider();
        coord.Attach(provider);

        provider.EmitFinal("confidential final");

        coord.SuppressedFinals.Should().Be(1);
        coord.FinalsSent.Should().Be(0);
        bridge.SentFrames.Should().BeEmpty();
    }

    // ── Task 6: Bridge receive safety constants are sensible ──────────────────

    [Fact]
    public void Bridge_max_frame_size_is_one_megabyte()
    {
        MacBridgeCoordinator.MaxReceiveFrameBytes.Should().Be(1_048_576);
    }

    [Fact]
    public void Bridge_per_message_timeout_is_ten_seconds()
    {
        MacBridgeCoordinator.ReceiveMessageTimeoutSeconds.Should().Be(10);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test doubles
    // ─────────────────────────────────────────────────────────────────────────

    private sealed class FakeBridge : IMacBridgeCoordinator
    {
        public BridgeStatus Status { get; }
        public List<SidecarFrame> SentFrames { get; } = new();
        public FakeBridge(BridgeState s) { Status = new BridgeStatus(s, DateTimeOffset.UtcNow, 0, null, null); }
        public event EventHandler<BridgeStatus>? StatusChanged { add { } remove { } }
        public event EventHandler<SidecarFrame>? FrameReceived;
        public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<bool> SendAsync(SidecarFrame f, CancellationToken c = default)
        {
            SentFrames.Add(f);
            return Task.FromResult(true);
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Receive(SidecarFrame f) => FrameReceived?.Invoke(this, f);
    }

    private sealed class MarkingLocalClient : ILlmClient
    {
        private readonly string _tag;
        public bool WasCalled { get; private set; }
        public MarkingLocalClient(string tag) { _tag = tag; }
        public bool IsConfigured => true;
        public async IAsyncEnumerable<string> StreamAsync(LlmRequest request,
            [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            WasCalled = true;
            await Task.CompletedTask;
            yield return _tag + " reply";
        }
    }

    private sealed class FakeSpeechProvider : ISpeechRecognitionProvider
    {
        public bool IsRecognizing => false;
        public event EventHandler<TranscriptEvent>? Partial;
        public event EventHandler<TranscriptEvent>? Final;
        public event EventHandler<bool>? RecognizingChanged { add { } remove { } }
        public void EmitPartial(string text) =>
            Partial?.Invoke(this, new TranscriptEvent(Guid.NewGuid().ToString("N"), text, 0.9, false, DateTimeOffset.UtcNow));
        public void EmitFinal(string text) =>
            Final?.Invoke(this, new TranscriptEvent(Guid.NewGuid().ToString("N"), text, 0.95, true, DateTimeOffset.UtcNow));
        public Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static LlmRequest MakeRequest() => new(
        SystemPrompt: "be terse",
        History: Array.Empty<ChatMessage>(),
        UserMessage: "hello",
        Context: ConversationContext.Empty);

    private static async Task<List<string>> CollectAsync(IAsyncEnumerable<string> stream)
    {
        var list = new List<string>();
        await foreach (var s in stream) list.Add(s);
        return list;
    }
}
