using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Owns the outbound WebSocket to the Mac brain / JarvisBrainDaemon.
///
/// Connection lifecycle:
///   - If <see cref="BrainGatewayConfig.BaseUrl"/> is empty → stays Disabled.
///   - If BaseUrl is set but no SessionToken → transitions to PairingRequired (user must pair).
///   - If BaseUrl and SessionToken are both set → connects to /v2/ws, sends
///     GatewayMessage envelopes, stops reconnecting on 401 or token-revoked nack.
///
/// Reconnects with exponential backoff; transitions to Degraded on sustained failure.
/// The session token is received after a successful pairing-code exchange — users never
/// see, copy, or paste it.
/// </summary>
public sealed class MacBridgeCoordinator : IMacBridgeCoordinator
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    public static readonly TimeSpan HeartbeatInterval          = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan DegradedAfter              = TimeSpan.FromSeconds(10);
    public static readonly int      OutboundQueueCap           = 256;
    public static readonly int      MaxReceiveFrameBytes       = 1_048_576;  // 1 MB
    public static readonly int      ReceiveMessageTimeoutSeconds = 10;

    private readonly Func<SidecarSettings>   _settings;
    private readonly Func<BrainGatewayConfig> _gateway;
    private readonly IDiagnostics?            _diagnostics;
    private readonly ILogger<MacBridgeCoordinator>? _logger;
    private readonly object _gate    = new();
    private readonly object _seqGate = new();

    private CancellationTokenSource? _cts;
    private Task? _runLoop;
    private ClientWebSocket? _socket;
    private DateTimeOffset _lastConnectAttempt   = DateTimeOffset.MinValue;
    private int  _reconnectAttempts;
    private double? _lastRttMs;
    private DateTimeOffset? _lastSuccessfulConnectAt;
    private DateTimeOffset? _degradedModeEnteredAt;
    private BridgeStatus _status = new(BridgeState.Disabled, DateTimeOffset.UtcNow, 0, null, null);
    private BlockingCollection<SidecarFrame> _outbound = new(OutboundQueueCap);
    private long _outboundSeq;
    private long _lastInboundSeq;
    private double? _lastHeartbeatRttMs;
    private DateTimeOffset _lastHeartbeatSentAt = DateTimeOffset.MinValue;

    private string _effectiveDeviceId = Environment.MachineName;
    // Set true when token is revoked or auth permanently fails — exits the reconnect loop.
    private volatile bool _stopReconnect;

    // ── Phase 10 diagnostics counters ─────────────────────────────────────────
    private int  _unauthorizedCount;
    private int  _tokenRevokedCount;
    private int  _transcriptSentCount;
    private int  _replyReceivedCount;
    private int  _executionRequestReceivedCount;
    private int  _executionResultSentCount;
    private int  _executionErrorSentCount;
    private int  _malformedFrameCount;
    private int  _staleFrameCount;
#pragma warning disable CS0649 // populated by RemoteExecutionDispatcher via IncrementCapabilityReject()
    private int  _capabilityRejectCount;
#pragma warning restore CS0649
    private string? _lastFrameType;
    private string? _lastRouteId;

    public int  UnauthorizedCount              => _unauthorizedCount;
    public int  TokenRevokedCount              => _tokenRevokedCount;
    public int  TranscriptSentCount            => _transcriptSentCount;
    public int  ReplyReceivedCount             => _replyReceivedCount;
    public int  ExecutionRequestReceivedCount  => _executionRequestReceivedCount;
    public int  ExecutionResultSentCount       => _executionResultSentCount;
    public int  ExecutionErrorSentCount        => _executionErrorSentCount;
    public int  MalformedFrameCount            => _malformedFrameCount;
    public int  CapabilityRejectCount          => _capabilityRejectCount;
    public string? LastFrameType               => _lastFrameType;
    public string? LastRouteId                 => _lastRouteId;

    public MacBridgeCoordinator(
        Func<SidecarSettings> settings,
        IDiagnostics? diagnostics = null,
        ILogger<MacBridgeCoordinator>? logger = null,
        Func<BrainGatewayConfig>? gateway = null)
    {
        _settings    = settings;
        _diagnostics = diagnostics;
        _logger      = logger;
        // Allow gateway config to be injected; default to empty config (Disabled state).
        _gateway = gateway ?? (() => new BrainGatewayConfig());
    }

    public BridgeStatus Status { get { lock (_gate) return _status; } }
    public event EventHandler<BridgeStatus>? StatusChanged;
    public event EventHandler<SidecarFrame>? FrameReceived;
    public double? LastHeartbeatRttMs => _lastHeartbeatRttMs;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_runLoop is not null) return Task.CompletedTask;
        // Recreate the outbound queue if it was completed by a previous StopAsync call.
        if (_outbound.IsAddingCompleted)
            _outbound = new BlockingCollection<SidecarFrame>(OutboundQueueCap);
        _cts     = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _runLoop = Task.Run(() => RunAsync(_cts.Token));
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (_cts is null) return;
        _cts.Cancel();
        _outbound.CompleteAdding();
        try { if (_runLoop is not null) await _runLoop.ConfigureAwait(false); } catch { }
        _runLoop = null;
        _cts = null;
        SetStatus(BridgeState.Disabled, null);
    }

    public Task<bool> SendAsync(SidecarFrame frame, CancellationToken cancellationToken = default)
    {
        if (_outbound.IsAddingCompleted) return Task.FromResult(false);
        frame.ProtocolVersion ??= SidecarProtocol.Version;
        frame.Seq             ??= Interlocked.Increment(ref _outboundSeq);
        while (_outbound.Count >= OutboundQueueCap - 1 && _outbound.TryTake(out _)) { }
        try { _outbound.Add(frame, cancellationToken); return Task.FromResult(true); }
        catch { return Task.FromResult(false); }
    }

    public IReadOnlyList<SidecarFrame> SnapshotOutbound()
    {
        var snapshot = new List<SidecarFrame>(_outbound.Count);
        snapshot.AddRange(_outbound);
        return snapshot;
    }

    // ── Run loop ──────────────────────────────────────────────────────────────

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var backoffMs = 500;
        _stopReconnect = false;
        while (!cancellationToken.IsCancellationRequested && !_stopReconnect)
        {
            var settings = _settings();
            var gateway  = _gateway();

            // ── Determine connection parameters ────────────────────────────────────
            // Only gateway-protocol is supported. Legacy bearer-token mode is removed.
            if (string.IsNullOrWhiteSpace(gateway.BaseUrl))
            {
                SetStatus(BridgeState.Disabled, null);
                try { await Task.Delay(1000, cancellationToken).ConfigureAwait(false); } catch { return; }
                continue;
            }

            var wsUrl     = gateway.DeriveWebSocketUrl();
            var authToken = gateway.SessionToken;

            if (string.IsNullOrWhiteSpace(wsUrl))
            {
                SetStatus(BridgeState.Disabled, "invalid gateway BaseUrl");
                try { await Task.Delay(2000, cancellationToken).ConfigureAwait(false); } catch { return; }
                continue;
            }

            if (string.IsNullOrWhiteSpace(authToken))
            {
                SetStatus(BridgeState.PairingRequired, "no session token — pair via Settings first");
                try { await Task.Delay(5000, cancellationToken).ConfigureAwait(false); } catch { return; }
                continue;
            }

            _effectiveDeviceId = !string.IsNullOrWhiteSpace(gateway.DeviceId)
                ? gateway.DeviceId
                : Environment.MachineName;

            SetStatus(BridgeState.Connecting, null);
            try
            {
                using var socket = new ClientWebSocket();
                if (!string.IsNullOrWhiteSpace(authToken))
                    socket.Options.SetRequestHeader("Authorization", $"Bearer {authToken}");

                await socket.ConnectAsync(new Uri(wsUrl), cancellationToken).ConfigureAwait(false);
                _socket = socket;
                _reconnectAttempts = 0;
                backoffMs = 500;
                lock (_seqGate) _lastInboundSeq = 0;
                SetStatus(BridgeState.Connected, null);

                // Handshake — always gateway protocol.
                await SendGatewayHelloAsync(socket, cancellationToken).ConfigureAwait(false);

                using var heartbeat = new CancellationTokenSource();
                using var loopCts   = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, heartbeat.Token);

                var send  = SendLoopAsync(socket, loopCts.Token);
                var recv  = ReceiveLoopAsync(socket, loopCts.Token);
                var beat  = HeartbeatLoopAsync(socket, loopCts.Token);

                await Task.WhenAny(send, recv, beat).ConfigureAwait(false);
                heartbeat.Cancel();
                try { await Task.WhenAll(send, recv, beat).ConfigureAwait(false); } catch { }
            }
            catch (OperationCanceledException) { return; }
            catch (WebSocketException ex) when (IsAuthFailure(ex))
            {
                Interlocked.Increment(ref _unauthorizedCount);
                _stopReconnect = true;
                _logger?.LogDebug("Bridge auth rejected — stopping reconnect");
                SetStatus(BridgeState.Unauthorized, "authentication rejected (401) — check token in Settings");
                return; // stop the run loop; user must reconfigure
            }
            catch (Exception ex)
            {
                _logger?.LogDebug(ex, "Bridge connect/run failed");
                SetStatus(BridgeState.Reconnecting, ex.Message);
            }
            finally
            {
                try { _socket?.Dispose(); } catch { }
                _socket = null;
            }

            _reconnectAttempts++;
            var dropAge = DateTimeOffset.UtcNow - _lastConnectAttempt;
            if (_reconnectAttempts >= 3 && dropAge > DegradedAfter)
                SetStatus(BridgeState.Degraded, "no Mac bridge");

            try { await Task.Delay(Math.Min(backoffMs, 15_000), cancellationToken).ConfigureAwait(false); }
            catch { return; }
            backoffMs = Math.Min(backoffMs * 2, 15_000);
        }
    }

    private static bool IsAuthFailure(WebSocketException ex) =>
        ex.Message.Contains("401", StringComparison.Ordinal) ||
        ex.Message.Contains("Unauthorized", StringComparison.OrdinalIgnoreCase) ||
        ex.WebSocketErrorCode == WebSocketError.NotAWebSocket;  // server returned non-101

    private async Task SendGatewayHelloAsync(ClientWebSocket socket, CancellationToken token)
    {
        var hello = GatewayMessageTranslator.ToGateway(new SidecarFrame
        {
            Type     = SidecarFrameTypes.Hello,
            DeviceId = _effectiveDeviceId,
            At       = DateTimeOffset.UtcNow
        }, _effectiveDeviceId);
        await SendGatewayInternalAsync(socket, hello, token).ConfigureAwait(false);

        // Immediately follow with capability.update so the daemon knows what we support.
        await SendGatewayInternalAsync(socket,
            GatewayMessageTranslator.BuildCapabilityUpdate(_effectiveDeviceId), token).ConfigureAwait(false);
    }

    // ── Send loop ─────────────────────────────────────────────────────────────

    private async Task SendLoopAsync(ClientWebSocket socket, CancellationToken token)
    {
        try
        {
            foreach (var frame in _outbound.GetConsumingEnumerable(token))
            {
                if (socket.State != WebSocketState.Open) return;
                TrackOutboundDiagnostics(frame);
                var msg = GatewayMessageTranslator.ToGateway(frame, _effectiveDeviceId);
                await SendGatewayInternalAsync(socket, msg, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _logger?.LogDebug(ex, "Bridge send loop ended"); }
    }

    private void TrackOutboundDiagnostics(SidecarFrame frame)
    {
        if (frame.Type == SidecarFrameTypes.TranscriptFinal)
            Interlocked.Increment(ref _transcriptSentCount);
        else if (frame.Type == SidecarFrameTypes.ExecuteAck)
        {
            if (frame.Outcome == "Succeeded") Interlocked.Increment(ref _executionResultSentCount);
            else Interlocked.Increment(ref _executionErrorSentCount);
        }
    }

    // ── Receive loop ──────────────────────────────────────────────────────────

    private async Task ReceiveLoopAsync(ClientWebSocket socket, CancellationToken token)
    {
        var buffer = new byte[16 * 1024];
        var ms     = new MemoryStream();
        while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
            ms.SetLength(0);
            var frameBytes = 0;
            WebSocketReceiveResult res;

            using var msgCts = CancellationTokenSource.CreateLinkedTokenSource(token);
            msgCts.CancelAfter(TimeSpan.FromSeconds(ReceiveMessageTimeoutSeconds));
            try
            {
                do
                {
                    res = await socket.ReceiveAsync(buffer, msgCts.Token).ConfigureAwait(false);
                    if (res.MessageType == WebSocketMessageType.Close) return;
                    frameBytes += res.Count;
                    if (frameBytes > MaxReceiveFrameBytes)
                    {
                        _diagnostics?.Record(DiagnosticLevel.Warn, "sidecar.bridge", "oversized frame rejected",
                            new Dictionary<string, object?> { ["bytes"] = frameBytes });
                        return;
                    }
                    ms.Write(buffer, 0, res.Count);
                } while (!res.EndOfMessage);
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "sidecar.bridge", "receive stall timeout");
                return;
            }

            var json = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
            SidecarFrame? frame = null;
            try
            {
                var msg = JsonSerializer.Deserialize<GatewayMessage>(json, JsonOpts);
                if (msg is not null) frame = GatewayMessageTranslator.FromGateway(msg);
            }
            catch
            {
                Interlocked.Increment(ref _malformedFrameCount);
                // malformed — ignore
            }

            if (frame is not null)
            {
                ProcessInboundFrame(frame);
                if (_stopReconnect) return;
            }
        }
    }

    private void ProcessInboundFrame(SidecarFrame frame)
    {
        // Check if daemon sent a token-revoked nack.
        if (frame.Type == GatewayMessageTypes.Nack
            && frame.Reason?.Contains("token_revoked", StringComparison.OrdinalIgnoreCase) == true)
        {
            Interlocked.Increment(ref _tokenRevokedCount);
            _stopReconnect = true;
            SetStatus(BridgeState.TokenRevoked, "session token revoked — re-pair via Settings");
            return;
        }

        // Track inbound diagnostics before seq filter.
        _lastFrameType = frame.Type;
        _lastRouteId   = frame.Id;
        if (frame.Type == SidecarFrameTypes.ChatReplyPartial ||
            frame.Type == SidecarFrameTypes.ChatReplyFinal)
            Interlocked.Increment(ref _replyReceivedCount);
        else if (frame.Type == SidecarFrameTypes.ExecuteIntent)
            Interlocked.Increment(ref _executionRequestReceivedCount);

        // Protocol v2: atomic seq check-and-advance.
        if (frame.Seq is { } seq)
        {
            bool drop;
            lock (_seqGate)
            {
                drop = seq <= _lastInboundSeq;
                if (!drop) _lastInboundSeq = seq;
            }
            if (drop)
            {
                Interlocked.Increment(ref _staleFrameCount);
                _diagnostics?.Record(DiagnosticLevel.Debug, "sidecar.bridge", "dropping stale frame",
                    new Dictionary<string, object?> { ["seq"] = seq });
                return;
            }
        }

        if (frame.Type == SidecarFrameTypes.Heartbeat && frame.At is { } at)
        {
            if (_lastHeartbeatSentAt != DateTimeOffset.MinValue)
            {
                var rtt = (DateTimeOffset.UtcNow - _lastHeartbeatSentAt).TotalMilliseconds;
                if (rtt is > 0 and < 60_000) _lastHeartbeatRttMs = rtt;
            }
            _lastRttMs = (DateTimeOffset.UtcNow - at).TotalMilliseconds;
        }
        FrameReceived?.Invoke(this, frame);
    }

    /// <summary>
    /// Test-only hook — calls ProcessInboundFrame without a real WebSocket.
    /// Accessible because Jarvis.Perception.Tests is listed in InternalsVisibleTo.
    /// </summary>
    internal void SimulateInboundForTest(SidecarFrame frame)
    {
        ProcessInboundFrame(frame);
    }

    // ── Heartbeat loop ────────────────────────────────────────────────────────

    private async Task HeartbeatLoopAsync(ClientWebSocket socket, CancellationToken token)
    {
        while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
            try { await Task.Delay(HeartbeatInterval, token).ConfigureAwait(false); } catch { return; }
            if (socket.State != WebSocketState.Open) return;
            _lastHeartbeatSentAt = DateTimeOffset.UtcNow;
            var heartbeat = new SidecarFrame
            {
                Type            = SidecarFrameTypes.Heartbeat,
                At              = _lastHeartbeatSentAt,
                ProtocolVersion = SidecarProtocol.Version,
                Seq             = Interlocked.Increment(ref _outboundSeq)
            };
            await SendGatewayInternalAsync(socket, GatewayMessageTranslator.ToGateway(heartbeat, _effectiveDeviceId), token).ConfigureAwait(false);
        }
    }

    // ── Wire helpers ──────────────────────────────────────────────────────────

    private static async Task SendGatewayInternalAsync(ClientWebSocket socket, GatewayMessage msg, CancellationToken token)
    {
        var json  = JsonSerializer.Serialize(msg, JsonOpts);
        var bytes = Encoding.UTF8.GetBytes(json);
        await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, token).ConfigureAwait(false);
    }

    // ── Status ────────────────────────────────────────────────────────────────

    private void SetStatus(BridgeState state, string? error)
    {
        BridgeStatus snapshot;
        bool transitioned;
        lock (_gate)
        {
            transitioned = _status.State != state;
            if (state == BridgeState.Connected) _lastSuccessfulConnectAt = DateTimeOffset.UtcNow;
            if (state == BridgeState.Degraded && _degradedModeEnteredAt is null) _degradedModeEnteredAt = DateTimeOffset.UtcNow;
            if (state == BridgeState.Connected) _degradedModeEnteredAt = null;
            _status = new BridgeStatus(state, DateTimeOffset.UtcNow, _reconnectAttempts, _lastRttMs, error,
                _lastSuccessfulConnectAt, _degradedModeEnteredAt);
            snapshot = _status;
            if (state == BridgeState.Connecting) _lastConnectAttempt = DateTimeOffset.UtcNow;
        }
        if (transitioned)
        {
            _diagnostics?.Record(DiagnosticLevel.Info, "sidecar.bridge", state.ToString(),
                new Dictionary<string, object?> { ["err"] = error, ["attempts"] = _reconnectAttempts });
            StatusChanged?.Invoke(this, snapshot);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        try { _outbound.Dispose(); } catch { }
        _cts?.Dispose();
    }
}
