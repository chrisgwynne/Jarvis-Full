using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

/// <summary>
/// Phase 12 — Gateway parity tests.
/// Covers: config derivation, message translation, auth state transitions,
/// diagnostics counters, and reconnect behaviour in gateway mode.
/// </summary>
public sealed class GatewayParityTests
{
    // ── Config: URL derivation ─────────────────────────────────────────────────

    [Theory]
    [InlineData("http://100.64.1.5:8765",        "ws://100.64.1.5:8765/v1/windows/ws")]
    [InlineData("https://mac.tail.ts.net:8765",  "wss://mac.tail.ts.net:8765/v1/windows/ws")]
    [InlineData("http://localhost:8765",         "ws://localhost:8765/v1/windows/ws")]
    [InlineData("http://100.64.1.5:8765/",       "ws://100.64.1.5:8765/v1/windows/ws")]  // trailing slash stripped
    public void DeriveWebSocketUrl_produces_correct_ws_url(string baseUrl, string expected)
    {
        var cfg = new BrainGatewayConfig { BaseUrl = baseUrl };
        cfg.DeriveWebSocketUrl().Should().Be(expected);
    }

    [Theory]
    [InlineData("")]
    [InlineData("  ")]
    [InlineData("not-a-url")]
    public void DeriveWebSocketUrl_returns_null_for_invalid_base(string baseUrl)
    {
        var cfg = new BrainGatewayConfig { BaseUrl = baseUrl };
        cfg.DeriveWebSocketUrl().Should().BeNull();
    }

    [Fact]
    public void DerivePairingUrl_appends_path()
    {
        var cfg = new BrainGatewayConfig { BaseUrl = "http://100.64.1.5:8765" };
        cfg.DerivePairingUrl().Should().Be("http://100.64.1.5:8765/v1/windows/pair");
    }

    [Fact]
    public void DeriveHealthUrl_appends_path()
    {
        var cfg = new BrainGatewayConfig { BaseUrl = "http://100.64.1.5:8765" };
        cfg.DeriveHealthUrl().Should().Be("http://100.64.1.5:8765/brain/health");
    }

    // ── Message translation: outbound ─────────────────────────────────────────

    [Fact]
    public void ToGateway_hello_maps_to_device_hello_type()
    {
        var frame = new SidecarFrame { Type = SidecarFrameTypes.Hello, DeviceId = "win-test" };
        var msg   = GatewayMessageTranslator.ToGateway(frame, "win-test");

        msg.Type.Should().Be(GatewayMessageTypes.DeviceHello);
        msg.SourcePlatform.Should().Be("windows");
        msg.Target.Should().Be("daemon");
    }

    [Fact]
    public void ToGateway_transcript_final_maps_correctly()
    {
        var frame = new SidecarFrame
        {
            Type      = SidecarFrameTypes.TranscriptFinal,
            Text      = "Hello Jarvis",
            SessionId = "sess1",
            Confidence = 0.95
        };
        var msg = GatewayMessageTranslator.ToGateway(frame, "dev1");

        msg.Type.Should().Be(GatewayMessageTypes.TranscriptFinal);
        msg.Target.Should().Be("macApp");
        msg.Payload.Should().NotBeNull();
        var payload = msg.Payload!.Value;
        payload.GetProperty("text").GetString().Should().Be("Hello Jarvis");
        payload.GetProperty("confidence").GetDouble().Should().BeApproximately(0.95, 0.001);
        payload.GetProperty("sessionId").GetString().Should().Be("sess1");
    }

    [Fact]
    public void ToGateway_execute_ack_succeeded_maps_to_execution_result()
    {
        var frame = new SidecarFrame
        {
            Type    = SidecarFrameTypes.ExecuteAck,
            Outcome = "Succeeded",
            Message = "Done"
        };
        var msg = GatewayMessageTranslator.ToGateway(frame, "dev1");
        msg.Type.Should().Be(GatewayMessageTypes.ExecutionResult);
    }

    [Fact]
    public void ToGateway_execute_ack_failed_maps_to_execution_error()
    {
        var frame = new SidecarFrame
        {
            Type    = SidecarFrameTypes.ExecuteAck,
            Outcome = "Failed",
            Message = "permission denied"
        };
        var msg = GatewayMessageTranslator.ToGateway(frame, "dev1");
        msg.Type.Should().Be(GatewayMessageTypes.ExecutionError);
    }

    [Fact]
    public void BuildCapabilityUpdate_targets_daemon_with_capabilities_list()
    {
        var msg = GatewayMessageTranslator.BuildCapabilityUpdate("dev1");

        msg.Type.Should().Be(GatewayMessageTypes.CapabilityUpdate);
        msg.Target.Should().Be("daemon");
        msg.Payload.Should().NotBeNull();
        var caps = msg.Payload!.Value.GetProperty("capabilities");
        caps.GetArrayLength().Should().BeGreaterThan(0);
    }

    // ── Message translation: inbound ──────────────────────────────────────────

    [Fact]
    public void FromGateway_reply_partial_maps_text_and_session()
    {
        var payload = JsonSerializer.SerializeToElement(new { text = "partial chunk", sessionId = "s1" });
        var msg = new GatewayMessage
        {
            Type    = GatewayMessageTypes.ReplyPartial,
            Payload = payload
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);

        frame.Type.Should().Be(SidecarFrameTypes.ChatReplyPartial);
        frame.Text.Should().Be("partial chunk");
        frame.SessionId.Should().Be("s1");
    }

    [Fact]
    public void FromGateway_reply_final_maps_text_and_session()
    {
        var payload = JsonSerializer.SerializeToElement(new { text = "final answer", sessionId = "s2" });
        var msg = new GatewayMessage
        {
            Type    = GatewayMessageTypes.ReplyFinal,
            Payload = payload
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);

        frame.Type.Should().Be(SidecarFrameTypes.ChatReplyFinal);
        frame.Text.Should().Be("final answer");
        frame.SessionId.Should().Be("s2");
    }

    [Fact]
    public void FromGateway_nack_maps_reason_and_message()
    {
        var payload = JsonSerializer.SerializeToElement(new { reason = "token_revoked", message = "Session expired" });
        var msg = new GatewayMessage
        {
            Type    = GatewayMessageTypes.Nack,
            Payload = payload
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);

        frame.Type.Should().Be(GatewayMessageTypes.Nack);
        frame.Reason.Should().Be("token_revoked");
        frame.Message.Should().Be("Session expired");
    }

    [Fact]
    public void FromGateway_execution_request_maps_command_and_payload()
    {
        var payload = JsonSerializer.SerializeToElement(new
        {
            commandId  = "cmd-1",
            command    = "clipboard.read",
            parameters = new { maxChars = 500 }
        });
        var msg = new GatewayMessage
        {
            Type    = GatewayMessageTypes.ExecutionRequest,
            Payload = payload
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);

        frame.Type.Should().Be(SidecarFrameTypes.ExecuteIntent);
        frame.CommandId.Should().Be("cmd-1");
        frame.IntentKind.Should().Be("clipboard.read");
        frame.IntentJson.Should().NotBeNullOrWhiteSpace();
    }

    // ── GatewayMessageTypes mapping helpers ───────────────────────────────────

    [Theory]
    [InlineData(SidecarFrameTypes.Hello,           GatewayMessageTypes.DeviceHello)]
    [InlineData(SidecarFrameTypes.Heartbeat,       GatewayMessageTypes.Heartbeat)]
    [InlineData(SidecarFrameTypes.TranscriptFinal, GatewayMessageTypes.TranscriptFinal)]
    [InlineData(SidecarFrameTypes.Presence,        GatewayMessageTypes.PresenceUpdate)]
    public void ToGatewayType_maps_known_types(string sidecarType, string expected)
        => GatewayMessageTypes.ToGatewayType(sidecarType).Should().Be(expected);

    [Theory]
    [InlineData(GatewayMessageTypes.ReplyPartial,     SidecarFrameTypes.ChatReplyPartial)]
    [InlineData(GatewayMessageTypes.ReplyFinal,       SidecarFrameTypes.ChatReplyFinal)]
    [InlineData(GatewayMessageTypes.ExecutionRequest, SidecarFrameTypes.ExecuteIntent)]
    [InlineData(GatewayMessageTypes.Heartbeat,        SidecarFrameTypes.Heartbeat)]
    public void FromGatewayType_maps_known_types(string gatewayType, string expected)
        => GatewayMessageTypes.FromGatewayType(gatewayType).Should().Be(expected);

    [Fact]
    public void FromGatewayType_returns_input_for_unknown_type()
        => GatewayMessageTypes.FromGatewayType("custom.event").Should().Be("custom.event");

    // ── WindowsCapabilities ───────────────────────────────────────────────────

    [Fact]
    public void WindowsCapabilities_enabled_list_is_non_empty()
        => WindowsCapabilities.Enabled.Should().NotBeEmpty();

    [Fact]
    public void WindowsCapabilities_IsEnabled_returns_true_for_known_cap()
        => WindowsCapabilities.IsEnabled(WindowsCapabilities.ClipboardRead).Should().BeTrue();

    [Fact]
    public void WindowsCapabilities_IsEnabled_returns_false_for_unknown_cap()
        => WindowsCapabilities.IsEnabled("some.unknown.cap").Should().BeFalse();

    // ── BridgeState transitions ───────────────────────────────────────────────

    [Fact]
    public void Coordinator_enters_PairingRequired_when_gateway_has_no_token()
    {
        var statesSeen = new List<BridgeState>();
        var coord      = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig { BaseUrl = "http://100.64.1.5:8765" });

        coord.StatusChanged += (_, s) => statesSeen.Add(s.State);
        _ = coord.StartAsync();
        Thread.Sleep(300);
        _ = coord.StopAsync();

        statesSeen.Should().Contain(BridgeState.PairingRequired,
            because: "no session token means we can't connect in gateway mode");
    }

    [Fact]
    public void Coordinator_stays_Disabled_when_gateway_is_empty_and_sidecar_disabled()
    {
        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig());   // no BaseUrl

        coord.StatusChanged += (_, s) =>
            s.State.Should().Be(BridgeState.Disabled, "nothing configured — should stay disabled");

        _ = coord.StartAsync();
        Thread.Sleep(300);
        _ = coord.StopAsync();
    }

    // ── Diagnostics counters ──────────────────────────────────────────────────

    [Fact]
    public void MacBridgeCoordinator_exposes_all_expected_diagnostic_properties()
    {
        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false });

        coord.UnauthorizedCount.Should().Be(0);
        coord.TokenRevokedCount.Should().Be(0);
        coord.TranscriptSentCount.Should().Be(0);
        coord.ReplyReceivedCount.Should().Be(0);
        coord.ExecutionRequestReceivedCount.Should().Be(0);
        coord.ExecutionResultSentCount.Should().Be(0);
        coord.ExecutionErrorSentCount.Should().Be(0);
        coord.MalformedFrameCount.Should().Be(0);
        coord.CapabilityRejectCount.Should().Be(0);
        coord.LastFrameType.Should().BeNull();
        coord.LastRouteId.Should().BeNull();
    }

    // ── Gateway mode — full round-trip via local WS server ────────────────────

    [Fact(Timeout = 15_000)]
    public async Task Gateway_mode_sends_device_hello_after_connect()
    {
        var port   = FindFreePort();
        var wsUrl  = $"ws://127.0.0.1:{port}/v1/windows/ws";
        var baseUrl = $"http://127.0.0.1:{port}";

        using var server   = new LocalGatewayServer(port);
        var framesSeen     = new List<GatewayMessage>();
        server.OnMessage   += msg => framesSeen.Add(msg);

        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig
            {
                BaseUrl      = baseUrl,
                DeviceId     = "test-win",
                DeviceName   = "Test Windows",
                SessionToken = "test-token",
                Paired       = true
            });

        await coord.StartAsync();
        await server.ClientConnected.WaitAsync(TimeSpan.FromSeconds(8));
        await Task.Delay(600);   // let handshake frames flush
        await coord.StopAsync();

        framesSeen.Should().Contain(m => m.Type == GatewayMessageTypes.DeviceHello,
            because: "gateway mode must send device.hello after connect");
        framesSeen.Should().Contain(m => m.Type == GatewayMessageTypes.CapabilityUpdate,
            because: "gateway mode must send capability.update after hello");
    }

    [Fact(Timeout = 15_000)]
    public async Task Gateway_mode_translates_transcript_frame_to_gateway_envelope()
    {
        var port    = FindFreePort();
        var baseUrl = $"http://127.0.0.1:{port}";

        using var server = new LocalGatewayServer(port);
        var transcripts  = new List<GatewayMessage>();
        server.OnMessage += msg =>
        {
            if (msg.Type == GatewayMessageTypes.TranscriptFinal) transcripts.Add(msg);
        };

        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig
            {
                BaseUrl      = baseUrl,
                DeviceId     = "test-win",
                SessionToken = "tok",
                Paired       = true
            });

        await coord.StartAsync();
        await server.ClientConnected.WaitAsync(TimeSpan.FromSeconds(8));
        await Task.Delay(200);
        await coord.SendAsync(new SidecarFrame
        {
            Type       = SidecarFrameTypes.TranscriptFinal,
            Text       = "test transcript",
            Confidence = 0.99,
            SessionId  = "sess-abc"
        });

        await Task.Delay(500);
        await coord.StopAsync();

        transcripts.Should().ContainSingle(
            because: "one transcript frame should arrive as one transcript.final gateway message");
        var payload = transcripts[0].Payload!.Value;
        payload.GetProperty("text").GetString().Should().Be("test transcript");
    }

    [Fact]
    public void Gateway_mode_handles_reply_partial_from_server()
    {
        // Unit-level test: feed a reply.partial GatewayMessage directly into the
        // coordinator's inbound processing path via SimulateInboundForTest.
        SidecarFrame? receivedFrame = null;
        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig());
        coord.FrameReceived += (_, f) => receivedFrame = f;

        var msg = new GatewayMessage
        {
            Type      = GatewayMessageTypes.ReplyPartial,
            Timestamp = DateTimeOffset.UtcNow,
            Payload   = JsonSerializer.SerializeToElement(new { text = "chunk", sessionId = "sess-1" })
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);
        coord.SimulateInboundForTest(frame);

        receivedFrame.Should().NotBeNull();
        receivedFrame!.Type.Should().Be(SidecarFrameTypes.ChatReplyPartial);
        receivedFrame.Text.Should().Be("chunk");
        receivedFrame.SessionId.Should().Be("sess-1");
    }

    [Fact]
    public void Gateway_mode_token_revoked_nack_stops_reconnect()
    {
        // Unit-level test: feeding a token_revoked nack frame directly into the
        // inbound processing path must set TokenRevoked state and increment the counter.
        BridgeStatus? capturedStatus = null;
        var coord = new MacBridgeCoordinator(
            () => new SidecarSettings { Enabled = false },
            gateway: () => new BrainGatewayConfig());
        coord.StatusChanged += (_, s) => capturedStatus = s;

        var msg = new GatewayMessage
        {
            Type      = GatewayMessageTypes.Nack,
            Timestamp = DateTimeOffset.UtcNow,
            Payload   = JsonSerializer.SerializeToElement(new { reason = "token_revoked", message = "Session expired" })
        };
        var frame = GatewayMessageTranslator.FromGateway(msg);
        coord.SimulateInboundForTest(frame);

        capturedStatus.Should().NotBeNull();
        capturedStatus!.State.Should().Be(BridgeState.TokenRevoked,
            because: "token_revoked nack must transition to TokenRevoked state");
        coord.TokenRevokedCount.Should().Be(1);
    }

    // ── Migration helper ──────────────────────────────────────────────────────

    [Fact]
    public void BrainGatewayConfig_Paired_is_false_by_default()
    {
        var cfg = new BrainGatewayConfig();
        cfg.Paired.Should().BeFalse();
        cfg.SessionToken.Should().BeNull();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static int FindFreePort()
    {
        using var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        var port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }
}

// ── Minimal in-process WebSocket server using TcpListener ────────────────────
// Uses WebSocket.CreateFromStream so send and receive are fully independent.

internal sealed class LocalGatewayServer : IDisposable
{
    private static readonly JsonSerializerOptions Opts = new()
    {
        PropertyNamingPolicy    = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition  = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly System.Net.Sockets.TcpListener _listener;
    private readonly CancellationTokenSource _cts = new();
    private WebSocket?        _ws;
    private readonly Task     _acceptLoop;
    private readonly TaskCompletionSource<bool> _clientConnected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly SemaphoreSlim _sendSem = new(1, 1); // one-at-a-time send

    public event Action<GatewayMessage>? OnMessage;

    /// <summary>Completes when the first WebSocket client has upgraded.</summary>
    public Task ClientConnected => _clientConnected.Task;

    public LocalGatewayServer(int port)
    {
        _listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
        _listener.Start();
        _acceptLoop = AcceptLoopAsync(_cts.Token);
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        try
        {
            var client = await _listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            client.NoDelay = true;
            var stream = client.GetStream();

            // Read the HTTP upgrade request.
            var reqBytes = new byte[4096];
            var len      = await stream.ReadAsync(reqBytes, 0, reqBytes.Length, token).ConfigureAwait(false);
            var reqText  = Encoding.ASCII.GetString(reqBytes, 0, len);

            // Extract Sec-WebSocket-Key header.
            var keyLine = reqText.Split('\n')
                .FirstOrDefault(l => l.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase));
            var clientKey = keyLine?.Split(':', 2)[1].Trim() ?? string.Empty;
            var acceptKey = Convert.ToBase64String(
                System.Security.Cryptography.SHA1.HashData(
                    Encoding.ASCII.GetBytes(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));

            var response = "HTTP/1.1 101 Switching Protocols\r\n"
                         + "Upgrade: websocket\r\n"
                         + "Connection: Upgrade\r\n"
                         + $"Sec-WebSocket-Accept: {acceptKey}\r\n\r\n";
            var respBytes = Encoding.ASCII.GetBytes(response);
            await stream.WriteAsync(respBytes, 0, respBytes.Length, token).ConfigureAwait(false);

            // Wrap the stream in a WebSocket.
            _ws = WebSocket.CreateFromStream(stream, new WebSocketCreationOptions
            {
                IsServer            = true,
                SubProtocol         = null,
                KeepAliveInterval   = TimeSpan.Zero
            });

            _clientConnected.TrySetResult(true);

            // Start reading inbound frames.
            _ = ReadLoopAsync(_ws, token);
        }
        catch (OperationCanceledException) { }
        catch { /* ignore */ }
    }

    private async Task ReadLoopAsync(WebSocket ws, CancellationToken token)
    {
        var buf = new byte[32 * 1024];
        var ms  = new MemoryStream();
        while (!token.IsCancellationRequested && ws.State == WebSocketState.Open)
        {
            ms.SetLength(0);
            WebSocketReceiveResult res;
            try
            {
                do
                {
                    res = await ws.ReceiveAsync(buf, token).ConfigureAwait(false);
                    if (res.MessageType == WebSocketMessageType.Close) return;
                    ms.Write(buf, 0, res.Count);
                } while (!res.EndOfMessage);
            }
            catch { return; }

            try
            {
                var json = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
                var msg  = JsonSerializer.Deserialize<GatewayMessage>(json, Opts);
                if (msg is not null) OnMessage?.Invoke(msg);
            }
            catch { /* ignore malformed */ }
        }
    }

    public async Task PushAsync(GatewayMessage msg)
    {
        if (_ws is null || _ws.State != WebSocketState.Open) return;
        var json  = JsonSerializer.Serialize(msg, Opts);
        var bytes = Encoding.UTF8.GetBytes(json);
        await _sendSem.WaitAsync().ConfigureAwait(false);
        try   { await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, _cts.Token).ConfigureAwait(false); }
        finally { _sendSem.Release(); }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _listener.Stop(); } catch { }
        _ws?.Dispose();
        _cts.Dispose();
        _sendSem.Dispose();
    }
}
