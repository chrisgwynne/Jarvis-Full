using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Jarvis.Core.Automation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Browser;

/// <summary>
/// Loopback WebSocket server. Now authenticated: clients must include a shared token in
/// the upgrade URL (<c>ws://127.0.0.1:PORT/?token=ABC</c>). Token lives in
/// <see cref="BridgeTokenStore"/>; the user pastes it into the extension's options page.
///
/// Direction is bidirectional in P3.5:
///   extension → host: hello, context, ping, ack
///   host → extension: command (navigate, click, …), each carrying a commandId
///
/// One connection at a time. A new authenticated client supersedes the previous socket.
/// </summary>
public sealed class WebSocketBrowserContextProvider : IBrowserContext, IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly int _port;
    private readonly BridgeTokenStore _tokens;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<WebSocketBrowserContextProvider>? _logger;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();
    private readonly ConcurrentDictionary<string, TaskCompletionSource<BrowserAck>> _pendingAcks = new();

    private HttpListener? _listener;
    private Task? _acceptLoop;
    private WebSocket? _currentSocket;
    private BrowserContextSnapshot _current = BrowserContextSnapshot.Empty;
    private bool _connected;
    private long _rejectedAuth;
    private long _acceptedAuth;

    public WebSocketBrowserContextProvider(
        BridgeTokenStore tokens,
        IDiagnostics? diagnostics = null,
        ILogger<WebSocketBrowserContextProvider>? logger = null,
        int port = 49321)
    {
        _tokens = tokens;
        _diagnostics = diagnostics;
        _logger = logger;
        _port = port;
    }

    public BrowserContextSnapshot Current { get { lock (_gate) return _current; } }
    public bool IsConnected { get { lock (_gate) return _connected; } }
    public event EventHandler<BrowserContextSnapshot>? Updated;

    public int Port => _port;
    public long AuthAccepted => Interlocked.Read(ref _acceptedAuth);
    public long AuthRejected => Interlocked.Read(ref _rejectedAuth);

    public async Task<bool> SendJsonAsync(string json, CancellationToken cancellationToken = default)
    {
        WebSocket? ws;
        lock (_gate) ws = _currentSocket;
        if (ws is null || ws.State != WebSocketState.Open) return false;
        try
        {
            var bytes = Encoding.UTF8.GetBytes(json);
            await ws.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "browser", "send failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return false;
        }
    }

    /// <summary>Send a typed command and await the matching ack. Returns a synthetic
    /// timeout/disconnect ack if the extension doesn't reply in time.</summary>
    public async Task<BrowserAck> SendCommandAsync(BrowserCommand command, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var commandId = command.CommandId ?? Guid.NewGuid().ToString("N");
        var payload = command with { CommandId = commandId };
        var tcs = new TaskCompletionSource<BrowserAck>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pendingAcks[commandId] = tcs;
        try
        {
            var json = JsonSerializer.Serialize(payload, JsonOpts);
            var ok = await SendJsonAsync(json, cancellationToken).ConfigureAwait(false);
            if (!ok)
            {
                return BrowserAck.Disconnected(commandId);
            }
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(timeout);
            using var _ = timeoutCts.Token.Register(() => tcs.TrySetResult(BrowserAck.Timeout(commandId)));
            return await tcs.Task.ConfigureAwait(false);
        }
        finally
        {
            _pendingAcks.TryRemove(commandId, out _);
        }
    }

    public void Start()
    {
        if (_listener is not null) return;
        try
        {
            // Pre-warm the token file so the user can copy it before the first connect.
            _tokens.GetOrCreate();
            _listener = new HttpListener();
            _listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
            _listener.Start();
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
            _diagnostics?.Record(DiagnosticLevel.Info, "browser", "bridge listening",
                new Dictionary<string, object?> { ["port"] = _port, ["tokenFile"] = _tokens.FilePath });
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "Browser bridge failed to bind");
            _diagnostics?.Record(DiagnosticLevel.Warn, "browser", "bridge bind failed",
                new Dictionary<string, object?> { ["port"] = _port, ["error"] = ex.Message });
            _listener = null;
        }
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _listener is { IsListening: true })
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync().ConfigureAwait(false); }
            catch (Exception) when (token.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "browser", "accept failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
                continue;
            }

            if (!ctx.Request.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 400;
                ctx.Response.Close();
                continue;
            }

            // Auth: token must match the on-disk shared secret.
            var presented = ctx.Request.QueryString["token"];
            var expected = _tokens.GetOrCreate();
            if (presented is null || !BridgeTokenStore.ConstantTimeEquals(presented, expected))
            {
                Interlocked.Increment(ref _rejectedAuth);
                _diagnostics?.Record(DiagnosticLevel.Warn, "browser", "auth rejected",
                    new Dictionary<string, object?> { ["remoteEndpoint"] = ctx.Request.RemoteEndPoint?.ToString() });
                ctx.Response.StatusCode = 401;
                ctx.Response.Close();
                continue;
            }

            Interlocked.Increment(ref _acceptedAuth);
            _ = Task.Run(() => HandleSocketAsync(ctx, token));
        }
    }

    private async Task HandleSocketAsync(HttpListenerContext ctx, CancellationToken token)
    {
        WebSocketContext wsCtx;
        try { wsCtx = await ctx.AcceptWebSocketAsync(subProtocol: null).ConfigureAwait(false); }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "browser", "ws accept failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return;
        }
        var ws = wsCtx.WebSocket;

        WebSocket? previous;
        lock (_gate)
        {
            previous = _currentSocket;
            _currentSocket = ws;
            _connected = true;
        }
        if (previous is not null)
        {
            try { await previous.CloseAsync(WebSocketCloseStatus.NormalClosure, "superseded", token).ConfigureAwait(false); } catch { }
        }

        _diagnostics?.Record(DiagnosticLevel.Info, "browser", "extension connected");
        var buffer = new byte[16 * 1024];
        var ms = new MemoryStream();
        try
        {
            while (!token.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                ms.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await ws.ReceiveAsync(buffer, token).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "client close", token).ConfigureAwait(false);
                        return;
                    }
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text) continue;
                var json = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
                HandleMessage(json);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "browser", "ws read ended",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_currentSocket, ws))
                {
                    _currentSocket = null;
                    _connected = false;
                    _current = BrowserContextSnapshot.Empty;
                }
            }
            // Fail any outstanding ack waits.
            foreach (var (id, tcs) in _pendingAcks.ToArray())
            {
                if (_pendingAcks.TryRemove(id, out var found)) found.TrySetResult(BrowserAck.Disconnected(id));
            }
            try { ws.Dispose(); } catch { }
            _diagnostics?.Record(DiagnosticLevel.Info, "browser", "extension disconnected");
            Updated?.Invoke(this, BrowserContextSnapshot.Empty);
        }
    }

    internal void HandleMessage(string json)
    {
        BrowserBridgeMessage? msg;
        try { msg = JsonSerializer.Deserialize<BrowserBridgeMessage>(json); }
        catch (JsonException ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "browser", "bad json",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return;
        }
        if (msg is null || string.IsNullOrEmpty(msg.Type)) return;

        switch (msg.Type)
        {
            case "hello":
                lock (_gate)
                {
                    _current = _current with
                    {
                        CapturedAt = DateTimeOffset.UtcNow,
                        Browser = msg.Browser ?? _current.Browser
                    };
                }
                Updated?.Invoke(this, Current);
                break;

            case "context":
                var next = new BrowserContextSnapshot(
                    CapturedAt: DateTimeOffset.UtcNow,
                    Browser: msg.Browser ?? Current.Browser,
                    Url: msg.Url,
                    Domain: msg.Domain ?? DeriveDomain(msg.Url),
                    Title: msg.Title,
                    SelectedText: msg.SelectedText,
                    FocusedElementRole: msg.FocusedElementRole,
                    IsTextInputFocused: msg.IsTextInputFocused ?? false);
                lock (_gate) _current = next;
                Updated?.Invoke(this, next);
                break;

            case "ack":
                if (!string.IsNullOrEmpty(msg.CommandId)
                    && _pendingAcks.TryRemove(msg.CommandId, out var tcs))
                {
                    var targets = msg.Targets?.Select(t => new BrowserDomTarget(
                        Label: t.Label ?? "",
                        Role: t.Role ?? "",
                        Selector: t.Selector ?? "",
                        X: t.X, Y: t.Y, Width: t.Width, Height: t.Height,
                        Visible: t.Visible, Enabled: t.Enabled)).ToList();
                    var viewport = msg.Viewport is null ? null : new BrowserViewport(
                        ScreenX: msg.Viewport.ScreenX,
                        ScreenY: msg.Viewport.ScreenY,
                        Width: msg.Viewport.Width,
                        Height: msg.Viewport.Height,
                        DevicePixelRatio: msg.Viewport.DevicePixelRatio <= 0 ? 1.0 : msg.Viewport.DevicePixelRatio,
                        ScrollX: msg.Viewport.ScrollX,
                        ScrollY: msg.Viewport.ScrollY);
                    tcs.TrySetResult(new BrowserAck(
                        CommandId: msg.CommandId,
                        Accepted: msg.Accepted ?? false,
                        Completed: msg.Completed ?? false,
                        Error: msg.Error,
                        ResultingUrl: msg.ResultingUrl,
                        ResultingTitle: msg.ResultingTitle,
                        Matches: msg.Matches,
                        Sample: msg.Sample,
                        Targets: targets,
                        Viewport: viewport));
                }
                break;

            case "ping":
                break;
        }
    }

    private static string? DeriveDomain(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri)) return uri.Host;
        return null;
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        try { _listener?.Stop(); } catch { }
        try { _listener?.Close(); } catch { }
        WebSocket? sock;
        lock (_gate) { sock = _currentSocket; _currentSocket = null; }
        if (sock is not null)
        {
            try { await sock.CloseAsync(WebSocketCloseStatus.NormalClosure, "shutdown", CancellationToken.None).ConfigureAwait(false); } catch { }
            try { sock.Dispose(); } catch { }
        }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        _cts.Dispose();
    }
}
