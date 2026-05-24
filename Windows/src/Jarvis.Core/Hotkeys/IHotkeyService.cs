namespace Jarvis.Core.Hotkeys;

/// <summary>
/// Placeholder seam for the global-hotkey subsystem. Phase 1 ships a no-op implementation
/// so callers can register listeners without depending on the (unbuilt) RegisterHotKey wiring.
/// </summary>
public interface IHotkeyService
{
    /// <summary>Register a hotkey by name. Returns true if registration was actually wired (false for the placeholder).</summary>
    bool Register(string name, string accelerator, Action callback);
    bool Unregister(string name);
    IReadOnlyDictionary<string, string> Registered { get; }
}

public sealed class NoopHotkeyService : IHotkeyService
{
    private readonly Dictionary<string, string> _registered = new(StringComparer.OrdinalIgnoreCase);

    public bool Register(string name, string accelerator, Action callback)
    {
        _registered[name] = accelerator;
        return false; // placeholder — no real binding yet
    }

    public bool Unregister(string name) => _registered.Remove(name);
    public IReadOnlyDictionary<string, string> Registered => _registered;
}
