using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Jarvis.Core.Settings;

namespace Jarvis.Settings;

/// <summary>
/// File-backed settings store. Writes atomically (temp + replace) so a crash mid-save
/// can't leave a half-written settings.json.
///
/// Sensitive fields (BridgeToken, Gateway.SessionToken) are encrypted at rest with DPAPI
/// CurrentUser scope. A "dpapi:" prefix marks encrypted values so plaintext tokens from
/// older versions are migrated transparently on first save.
/// Phase 11: on first load, if Gateway.BaseUrl is empty but Sidecar.BridgeUrl is set, the
/// legacy URL and token are promoted into BrainGatewayConfig automatically.
/// </summary>
public sealed class JsonSettingsStore : IJarvisSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly string _path;
    private readonly object _gate = new();
    private JarvisSettings _current = JarvisSettings.Defaults;

    public JsonSettingsStore(string? path = null)
    {
        _path = path ?? DefaultPath();
    }

    public JarvisSettings Current
    {
        get { lock (_gate) return _current; }
    }

    public event EventHandler<JarvisSettings>? Changed;

    public static string DefaultPath()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(roaming, "Jarvis", "settings.json");
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        JarvisSettings loaded;
        if (!File.Exists(_path))
        {
            loaded = JarvisSettings.Defaults;
            await SaveAsync(loaded, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            try
            {
                await using var stream = File.OpenRead(_path);
                loaded = await JsonSerializer.DeserializeAsync<JarvisSettings>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
                         ?? JarvisSettings.Defaults;
                // Decrypt any DPAPI-protected fields before handing to callers.
                if (OperatingSystem.IsWindows()) loaded = DecryptSensitive(loaded);
                // Phase 11 migration: promote legacy BridgeUrl/BridgeToken into BrainGatewayConfig.
                loaded = MigrateGatewayConfig(loaded);
            }
            catch (JsonException)
            {
                // corrupt file — back it up and reset
                File.Move(_path, _path + ".corrupt." + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), overwrite: true);
                loaded = JarvisSettings.Defaults;
                await SaveAsync(loaded, cancellationToken).ConfigureAwait(false);
            }
        }
        lock (_gate) _current = loaded;
        Changed?.Invoke(this, loaded);
    }

    public async Task SaveAsync(JarvisSettings settings, CancellationToken cancellationToken = default)
    {
        // Encrypt sensitive fields before writing to disk; callers always work with plaintext.
        var toWrite = OperatingSystem.IsWindows() ? EncryptSensitive(settings) : settings;
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var tmp = _path + ".tmp";
        await using (var stream = File.Create(tmp))
        {
            await JsonSerializer.SerializeAsync(stream, toWrite, JsonOptions, cancellationToken).ConfigureAwait(false);
        }
        File.Move(tmp, _path, overwrite: true);
        // Keep the in-memory copy as plaintext so the rest of the app never sees ciphertext.
        lock (_gate) _current = settings;
        Changed?.Invoke(this, settings);
    }

    // ── DPAPI helpers ─────────────────────────────────────────────────────────

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static JarvisSettings EncryptSensitive(JarvisSettings s)
    {
        // Encrypt legacy BridgeToken.
        var legacyToken = s.Sidecar.BridgeToken;
        if (!string.IsNullOrEmpty(legacyToken) && !TokenCrypto.IsProtected(legacyToken))
        {
            try { s = s with { Sidecar = s.Sidecar with { BridgeToken = TokenCrypto.Protect(legacyToken) } }; }
            catch { /* DPAPI unavailable — keep plaintext */ }
        }
        // Encrypt gateway SessionToken.
        var gwToken = s.Gateway.SessionToken;
        if (!string.IsNullOrEmpty(gwToken) && !TokenCrypto.IsProtected(gwToken))
        {
            try { s = s with { Gateway = s.Gateway with { SessionToken = TokenCrypto.Protect(gwToken) } }; }
            catch { /* DPAPI unavailable — keep plaintext */ }
        }
        return s;
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static JarvisSettings DecryptSensitive(JarvisSettings s)
    {
        // Decrypt legacy BridgeToken.
        if (TokenCrypto.IsProtected(s.Sidecar.BridgeToken))
        {
            try { s = s with { Sidecar = s.Sidecar with { BridgeToken = TokenCrypto.Unprotect(s.Sidecar.BridgeToken!) } }; }
            catch { s = s with { Sidecar = s.Sidecar with { BridgeToken = null } }; }
        }
        // Decrypt gateway SessionToken.
        if (TokenCrypto.IsProtected(s.Gateway.SessionToken))
        {
            try { s = s with { Gateway = s.Gateway with { SessionToken = TokenCrypto.Unprotect(s.Gateway.SessionToken!) } }; }
            catch { s = s with { Gateway = s.Gateway with { SessionToken = null, Paired = false } }; }
        }
        return s;
    }

    /// <summary>
    /// Phase 11 migration: if Gateway has never been configured but the legacy Sidecar bridge is
    /// enabled, derive BaseUrl from BridgeUrl and copy BridgeToken as the initial SessionToken.
    /// Marks <see cref="BrainGatewayConfig.MigratedFromLegacy"/> so this runs only once.
    /// </summary>
    private static JarvisSettings MigrateGatewayConfig(JarvisSettings s)
    {
        // Only migrate if gateway hasn't been touched yet and legacy bridge has a URL.
        if (s.Gateway.MigratedFromLegacy) return s;
        if (!string.IsNullOrWhiteSpace(s.Gateway.BaseUrl)) return s;

        var legacyUrl = s.Sidecar.BridgeUrl;
        if (string.IsNullOrWhiteSpace(legacyUrl)) return s;

        // Convert ws://host:port/... → http://host:port
        string? httpBase = null;
        if (Uri.TryCreate(legacyUrl, UriKind.Absolute, out var u))
        {
            var httpScheme = u.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase) ? "https" : "http";
            var port = u.IsDefaultPort ? string.Empty : $":{u.Port}";
            httpBase = $"{httpScheme}://{u.Host}{port}";
        }

        if (string.IsNullOrWhiteSpace(httpBase)) return s;

        return s with
        {
            Gateway = s.Gateway with
            {
                BaseUrl               = httpBase,
                DeviceId              = string.IsNullOrWhiteSpace(s.Gateway.DeviceId)
                                            ? Environment.MachineName
                                            : s.Gateway.DeviceId,
                DeviceName            = string.IsNullOrWhiteSpace(s.Gateway.DeviceName)
                                            ? s.Sidecar.DeviceName
                                            : s.Gateway.DeviceName,
                // SessionToken from legacy; treated as unpairedtoken — user still needs to pair.
                SessionToken          = s.Sidecar.BridgeToken,
                MigratedFromLegacy    = true,
                MigrationCompletedAt  = DateTimeOffset.UtcNow
            }
        };
    }

    private static class TokenCrypto
    {
        private const string Prefix = "dpapi:";

        public static bool IsProtected(string? s) =>
            s?.StartsWith(Prefix, StringComparison.Ordinal) == true;

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        public static string Protect(string plaintext)
        {
            var bytes = Encoding.UTF8.GetBytes(plaintext);
            var enc = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
            return Prefix + Convert.ToBase64String(enc);
        }

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        public static string Unprotect(string protected_)
        {
            var enc = Convert.FromBase64String(protected_[Prefix.Length..]);
            var dec = ProtectedData.Unprotect(enc, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(dec);
        }
    }
}
