namespace Jarvis.Core.Presence;

public enum PresenceMode
{
    Work,
    Focus,
    Casual,
    Gaming,
    Presentation,
    Silent,
    Developer
}

public interface IPresenceModeManager
{
    PresenceMode Current { get; }
    bool IsUserOverride { get; }
    event EventHandler<PresenceMode>? ModeChanged;
    void SetMode(PresenceMode mode);
    void ClearOverride();
    Task StartAsync(CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
}
