using System.IO;
using System.Security.Cryptography;

namespace Jarvis.Perception.Browser;

/// <summary>
/// Generates and persists the shared secret the browser extension uses to authenticate.
/// On first launch a 32-byte token is created and written to
///   <c>%APPDATA%\Jarvis\bridge-token.txt</c>
/// Subsequent launches reuse the same token unless the user deletes the file
/// (which is the documented way to revoke + rotate).
///
/// The token is base64url-encoded so it fits in a WebSocket URL query string.
/// </summary>
public sealed class BridgeTokenStore
{
    private readonly string _path;
    private string? _cached;

    public BridgeTokenStore(string? path = null) => _path = path ?? DefaultPath();

    public static string DefaultPath()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(roaming, "Jarvis", "bridge-token.txt");
    }

    public string FilePath => _path;

    public string GetOrCreate()
    {
        if (_cached is not null) return _cached;
        if (File.Exists(_path))
        {
            var read = File.ReadAllText(_path).Trim();
            if (read.Length >= 32)
            {
                _cached = read;
                return _cached;
            }
        }
        var bytes = RandomNumberGenerator.GetBytes(32);
        var token = Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, token);
        _cached = token;
        return token;
    }

    /// <summary>Constant-time compare — token strings are short but we still avoid the timing leak.</summary>
    public static bool ConstantTimeEquals(string a, string b)
    {
        if (a.Length != b.Length) return false;
        var diff = 0;
        for (var i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
        return diff == 0;
    }
}
