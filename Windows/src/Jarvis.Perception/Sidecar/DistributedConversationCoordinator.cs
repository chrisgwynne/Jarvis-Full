using System.IO;
using System.Text.Json;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// File-backed implementation. The session id + device id are persisted to
/// <c>%AppData%\Jarvis\distributed.json</c> so a Windows restart resumes the same
/// conversation context the Mac brain already knows. Wake alias is read live from
/// settings each access (cheap; the user may rename it mid-session).
///
/// Storage shape (forward-compatible — new fields default):
///   { "sessionId": "...", "deviceId": "..." }
/// </summary>
public sealed class DistributedConversationCoordinator : IDistributedConversationCoordinator
{
    private const string FileName = "distributed.json";

    private readonly Func<SidecarSettings> _settings;
    private readonly string _path;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();
    private string _sessionId;
    private string _deviceId;

    public string SessionId { get { lock (_gate) return _sessionId; } }
    public string DeviceId { get { lock (_gate) return _deviceId; } }
    public string WakeAlias => string.IsNullOrWhiteSpace(_settings().LocalWakeAlias)
        ? _settings().EffectiveWakeAlias : _settings().LocalWakeAlias;

    public event EventHandler? SessionRotated;

    public DistributedConversationCoordinator(
        Func<SidecarSettings> settings,
        string? storeDirectory = null,
        IDiagnostics? diagnostics = null)
    {
        _settings = settings;
        _diagnostics = diagnostics;
        var dir = storeDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jarvis");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, FileName);
        (_sessionId, _deviceId) = LoadOrInit();
    }

    public void RotateSession(string reason)
    {
        string newId;
        lock (_gate)
        {
            newId = Guid.NewGuid().ToString("N");
            _sessionId = newId;
            Persist();
        }
        _diagnostics?.Record(DiagnosticLevel.Info, "conversation.session", "rotated",
            new Dictionary<string, object?> { ["reason"] = reason, ["sessionId"] = newId });
        SessionRotated?.Invoke(this, EventArgs.Empty);
    }

    private (string session, string device) LoadOrInit()
    {
        try
        {
            if (File.Exists(_path))
            {
                using var fs = File.OpenRead(_path);
                var doc = JsonDocument.Parse(fs);
                var session = doc.RootElement.TryGetProperty("sessionId", out var s) ? s.GetString() : null;
                var device = doc.RootElement.TryGetProperty("deviceId", out var d) ? d.GetString() : null;
                if (!string.IsNullOrEmpty(session) && !string.IsNullOrEmpty(device))
                    return (session!, device!);
            }
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "conversation.session", "load failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
        var seeded = (Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"));
        _sessionId = seeded.Item1; _deviceId = seeded.Item2;
        Persist();
        return seeded;
    }

    private void Persist()
    {
        try
        {
            var json = JsonSerializer.Serialize(new { sessionId = _sessionId, deviceId = _deviceId });
            File.WriteAllText(_path, json);
        }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "conversation.session", "persist failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }
}
