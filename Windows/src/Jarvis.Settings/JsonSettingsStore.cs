using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Jarvis.Core.Settings;

namespace Jarvis.Settings;

/// <summary>
/// File-backed settings store. Writes atomically (temp + replace) so a crash mid-save
/// can't leave a half-written settings.json.
///
/// Sensitive fields (Gateway.SessionToken) are encrypted at rest with DPAPI CurrentUser
/// scope. A "dpapi:" prefix marks encrypted values so plaintext tokens from older versions
/// are migrated transparently on first save.
///
/// Old JSON files that contain the removed BridgeUrl / BridgeToken / SidecarEnabled fields
/// are silently ignored — the JSON deserializer discards unknown properties.
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
        var gwToken = s.Gateway.SessionToken;
        if (!string.IsNullOrEmpty(gwToken) && !TokenCrypto.IsProtected(gwToken))
        {
            try { s = s with { Gateway = s.Gateway with { SessionToken = TokenCrypto.Protect(gwToken) } }; }
            catch { /* DPAPI unavailable — keep plaintext */ }
        }
        // LLM API key (#32)
        var apiKey = s.Llm.ApiKey;
        if (!string.IsNullOrEmpty(apiKey) && !TokenCrypto.IsProtected(apiKey))
        {
            try { s = s with { Llm = s.Llm with { ApiKey = TokenCrypto.Protect(apiKey) } }; }
            catch { /* DPAPI unavailable — keep plaintext */ }
        }
        return s;
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static JarvisSettings DecryptSensitive(JarvisSettings s)
    {
        if (TokenCrypto.IsProtected(s.Gateway.SessionToken))
        {
            try { s = s with { Gateway = s.Gateway with { SessionToken = TokenCrypto.Unprotect(s.Gateway.SessionToken!) } }; }
            catch { s = s with { Gateway = s.Gateway with { SessionToken = null, Paired = false } }; }
        }
        // LLM API key (#32)
        if (TokenCrypto.IsProtected(s.Llm.ApiKey))
        {
            try { s = s with { Llm = s.Llm with { ApiKey = TokenCrypto.Unprotect(s.Llm.ApiKey!) } }; }
            catch { s = s with { Llm = s.Llm with { ApiKey = null } }; }
        }
        return s;
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
