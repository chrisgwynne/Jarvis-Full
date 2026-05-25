using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// HTTP client for the Windows pairing flow against the Mac Brain Gateway.
///
/// POST /v1/windows/pair → receive session token → store via settings.
///
/// The session token is never logged in full. After pairing, all subsequent
/// requests (HTTP and WebSocket) use Authorization: Bearer {sessionToken}.
/// </summary>
public static class GatewayPairingClient
{
    private static readonly JsonSerializerOptions Opts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public sealed record PairingResult(
        bool   Success,
        string? SessionToken,
        string? DeviceId,
        DateTimeOffset? ExpiresAt,
        IReadOnlyList<string>? AllowedCapabilities,
        string? Error);

    /// <summary>
    /// Attempt to pair this Windows device with the Mac Brain Gateway.
    /// </summary>
    /// <param name="baseUrl">Gateway base URL, e.g. <c>http://100.64.1.5:8765</c></param>
    /// <param name="deviceId">Stable device identifier for this Windows machine.</param>
    /// <param name="deviceName">Human-readable name shown in Mac Brain admin.</param>
    /// <param name="pairingCode">One-time code displayed on Mac Brain to authenticate the pair.</param>
    /// <param name="appVersion">Windows app version string.</param>
    /// <param name="capabilities">Capability identifiers this client advertises.</param>
    public static async Task<PairingResult> PairAsync(
        string baseUrl,
        string deviceId,
        string deviceName,
        string pairingCode,
        string appVersion,
        IEnumerable<string> capabilities,
        CancellationToken cancellationToken = default)
    {
        var pairingUrl = $"{baseUrl.TrimEnd('/')}/v1/windows/pair";

        using var http   = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var bodyJson     = JsonSerializer.Serialize(new
        {
            deviceId,
            deviceName,
            code = pairingCode,
            appVersion,
            capabilities = capabilities.ToArray()
        }, Opts);

        using var req = new HttpRequestMessage(HttpMethod.Post, pairingUrl)
        {
            Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
        };

        HttpResponseMessage resp;
        try
        {
            resp = await http.SendAsync(req, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return new PairingResult(false, null, null, null, null,
                $"network error: {ex.Message}");
        }

        string responseBody;
        try { responseBody = await resp.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false); }
        catch { responseBody = ""; }

        if (!resp.IsSuccessStatusCode)
        {
            var detail = TryExtractError(responseBody) ?? resp.ReasonPhrase ?? $"{(int)resp.StatusCode}";
            return new PairingResult(false, null, null, null, null,
                $"HTTP {(int)resp.StatusCode}: {detail}");
        }

        JsonDocument doc;
        try { doc = JsonDocument.Parse(responseBody); }
        catch { return new PairingResult(false, null, null, null, null, "invalid JSON in response"); }

        using (doc)
        {
            var root = doc.RootElement;

            string? Str(string k)   => root.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            DateTimeOffset? DTO(string k) => root.TryGetProperty(k, out var v) && v.TryGetDateTimeOffset(out var dt) ? dt : null;

            var token = Str("sessionToken");
            if (string.IsNullOrWhiteSpace(token))
                return new PairingResult(false, null, null, null, null, "response missing sessionToken");

            IReadOnlyList<string>? caps = null;
            if (root.TryGetProperty("allowedCapabilities", out var capsEl))
                caps = capsEl.EnumerateArray()
                    .Select(e => e.GetString() ?? "")
                    .Where(s => s.Length > 0)
                    .ToList();

            return new PairingResult(
                Success:              true,
                SessionToken:         token,
                DeviceId:             Str("deviceId"),
                ExpiresAt:            DTO("expiresAt"),
                AllowedCapabilities:  caps,
                Error:                null);
        }
    }

    private static string? TryExtractError(string body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var v)) return v.GetString();
            if (doc.RootElement.TryGetProperty("message", out v)) return v.GetString();
        }
        catch { /* ignore */ }
        return body.Length > 200 ? body[..200] : body;
    }
}
