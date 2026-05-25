using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.WebSockets;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Staged connectivity probe for the Mac brain bridge. Each stage provides an actionable
/// next-action hint so users can self-diagnose Tailscale + firewall + binding issues.
///
/// Stages: URL validation → DNS → TCP → HTTP /brain/health → WebSocket upgrade.
/// A stage failure stops the chain — no point checking WebSocket if TCP is closed.
/// </summary>
public static class BridgeConnectivityProbe
{
    public static async Task<ProbeResult> RunAsync(
        string bridgeUrl,
        string? token,
        CancellationToken cancellationToken = default)
    {
        var stages = new List<ProbeStage>();

        // ── Stage 1: URL validation ────────────────────────────────────────────
        if (!Uri.TryCreate(bridgeUrl, UriKind.Absolute, out var uri) ||
            (!uri.Scheme.Equals("ws", StringComparison.OrdinalIgnoreCase) &&
             !uri.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase)))
        {
            stages.Add(new ProbeStage("URL", false,
                $"Not a valid ws:// or wss:// URL: \"{bridgeUrl}\"",
                "Enter a WebSocket URL, e.g. ws://100.64.1.5:8765/v2/ws"));
            return new ProbeResult(stages);
        }

        var isLocalhost = uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
                       || uri.Host == "127.0.0.1"
                       || uri.Host == "::1";
        stages.Add(new ProbeStage("URL", true,
            isLocalhost
                ? $"{bridgeUrl}  ⚠ localhost — only works when Mac runs on this machine. Use Tailscale IP or MagicDNS for cross-machine."
                : bridgeUrl,
            null));

        // ── Stage 2: DNS ───────────────────────────────────────────────────────
        System.Net.IPAddress[]? addrs;
        try
        {
            using var dnsCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            dnsCts.CancelAfter(TimeSpan.FromSeconds(4));
            addrs = await System.Net.Dns.GetHostAddressesAsync(uri.Host, dnsCts.Token).ConfigureAwait(false);
            if (addrs.Length == 0) throw new Exception("no addresses returned");
            stages.Add(new ProbeStage("DNS", true, $"{uri.Host} → {addrs[0]}", null));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            stages.Add(new ProbeStage("DNS", false,
                $"DNS lookup timed out for \"{uri.Host}\".",
                "Check host name and that Tailscale is running (tailscale status)."));
            return new ProbeResult(stages);
        }
        catch (Exception ex)
        {
            stages.Add(new ProbeStage("DNS", false,
                $"Cannot resolve \"{uri.Host}\": {ex.Message}",
                "Use the raw Tailscale IP (tailscale ip -4 on Mac) or check MagicDNS spelling."));
            return new ProbeResult(stages);
        }

        // ── Stage 3: TCP ───────────────────────────────────────────────────────
        var port = uri.IsDefaultPort
            ? (uri.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase) ? 443 : 80)
            : uri.Port;
        try
        {
            using var tcpCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            tcpCts.CancelAfter(TimeSpan.FromSeconds(4));
            using var tcp = new System.Net.Sockets.TcpClient();
            await tcp.ConnectAsync(addrs[0], port, tcpCts.Token).ConfigureAwait(false);
            stages.Add(new ProbeStage("TCP", true, $"Port {port} open on {addrs[0]}.", null));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            stages.Add(new ProbeStage("TCP", false,
                $"TCP connect to {addrs[0]}:{port} timed out.",
                "Mac Brain API may be bound to 127.0.0.1 only. On Mac: change host to \"0.0.0.0\" so it's reachable over Tailscale, then restart."));
            return new ProbeResult(stages);
        }
        catch (Exception ex)
        {
            stages.Add(new ProbeStage("TCP", false,
                $"TCP connect failed: {ex.Message}",
                "Mac Brain API may be bound to 127.0.0.1 only. On Mac: change host to \"0.0.0.0\" so it's reachable over Tailscale, then restart."));
            return new ProbeResult(stages);
        }

        // ── Stage 4: HTTP /brain/health ───────────────────────────────────────
        var httpScheme = uri.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase) ? "https" : "http";
        var portSuffix = uri.IsDefaultPort ? string.Empty : $":{uri.Port}";
        var healthUrl = $"{httpScheme}://{uri.Host}{portSuffix}/brain/health";
        try
        {
            using var httpCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            httpCts.CancelAfter(TimeSpan.FromSeconds(6));
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get, healthUrl);
            if (!string.IsNullOrEmpty(token))
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var resp = await http.SendAsync(req, httpCts.Token).ConfigureAwait(false);
            if ((int)resp.StatusCode == 401)
            {
                stages.Add(new ProbeStage("HTTP", false,
                    "401 — authentication failed.",
                    "Your session token may have expired. Go to Settings → Mac Brain and pair again to get a fresh token."));
                return new ProbeResult(stages);
            }
            if (!resp.IsSuccessStatusCode)
            {
                stages.Add(new ProbeStage("HTTP", false,
                    $"HTTP {(int)resp.StatusCode}: {resp.ReasonPhrase} ({healthUrl})",
                    "Check that Mac Brain API is running and the /brain/health path exists."));
                return new ProbeResult(stages);
            }
            stages.Add(new ProbeStage("HTTP", true, $"/brain/health → {(int)resp.StatusCode} OK", null));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            stages.Add(new ProbeStage("HTTP", false,
                "HTTP health check timed out.",
                "Mac Brain API is reachable over TCP but not responding to HTTP — it may be starting up."));
            return new ProbeResult(stages);
        }
        catch (Exception ex)
        {
            stages.Add(new ProbeStage("HTTP", false, $"HTTP error: {ex.Message}", null));
            return new ProbeResult(stages);
        }

        // ── Stage 5: WebSocket upgrade ────────────────────────────────────────
        try
        {
            using var wsCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            wsCts.CancelAfter(TimeSpan.FromSeconds(6));
            using var ws = new ClientWebSocket();
            ws.Options.SetRequestHeader("X-Jarvis-Sidecar", "v2");
            if (!string.IsNullOrEmpty(token))
                ws.Options.SetRequestHeader("Authorization", $"Bearer {token}");
            await ws.ConnectAsync(new Uri(bridgeUrl), wsCts.Token).ConfigureAwait(false);
            stages.Add(new ProbeStage("WebSocket", true,
                "WebSocket upgrade succeeded — bridge is fully reachable.", null));
            try { await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "probe", CancellationToken.None).ConfigureAwait(false); }
            catch { /* best-effort close */ }
        }
        catch (WebSocketException ex) when (
            ex.Message.Contains("401", StringComparison.OrdinalIgnoreCase) ||
            ex.Message.Contains("Unauthorized", StringComparison.OrdinalIgnoreCase))
        {
            stages.Add(new ProbeStage("WebSocket", false,
                "WebSocket rejected — 401 Unauthorized.",
                "Token valid for HTTP but rejected on WebSocket — check Authorization header handling on Mac."));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            stages.Add(new ProbeStage("WebSocket", false,
                "WebSocket upgrade timed out.",
                "TCP and HTTP work but WS upgrade failed — check Mac WS handler (/v2/ws path)."));
        }
        catch (Exception ex)
        {
            stages.Add(new ProbeStage("WebSocket", false, $"WebSocket error: {ex.Message}", null));
        }

        return new ProbeResult(stages);
    }

    /// <summary>Derives the HTTP health URL from a WebSocket bridge URL. Used by tests.</summary>
    internal static Uri? ToHealthUrl(string bridgeUrl)
    {
        if (string.IsNullOrWhiteSpace(bridgeUrl)) return null;
        if (!Uri.TryCreate(bridgeUrl, UriKind.Absolute, out var u)) return null;
        string httpScheme;
        if (u.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase)) httpScheme = "https";
        else if (u.Scheme.Equals("ws", StringComparison.OrdinalIgnoreCase)) httpScheme = "http";
        else return null; // only transform ws/wss
        var port = u.IsDefaultPort ? string.Empty : $":{u.Port}";
        return new Uri($"{httpScheme}://{u.Host}{port}/brain/health");
    }
}

public sealed record ProbeStage(string Label, bool Ok, string Detail, string? NextAction);

public sealed record ProbeResult(IReadOnlyList<ProbeStage> Stages)
{
    public bool AllOk => Stages.All(s => s.Ok);
    public ProbeStage? FirstFailure => Stages.FirstOrDefault(s => !s.Ok);

    public string FormatText()
    {
        var sb = new System.Text.StringBuilder();
        foreach (var s in Stages)
        {
            sb.AppendLine($"{(s.Ok ? "✓" : "✗")} {s.Label,-10} {s.Detail}");
            if (!s.Ok && s.NextAction is not null)
                sb.AppendLine($"  → {s.NextAction}");
        }
        return sb.ToString().TrimEnd();
    }
}
