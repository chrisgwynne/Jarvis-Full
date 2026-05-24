namespace Jarvis.Core.Awareness;

public interface IDesktopAwarenessService : IAsyncDisposable
{
    /// <summary>Most recent snapshot, or null before the first poll.</summary>
    DesktopSnapshot? Latest { get; }

    /// <summary>Fires on every meaningful change (foreground app, idle transition, monitor move).</summary>
    event EventHandler<DesktopSnapshot>? SnapshotChanged;

    Task StartAsync(CancellationToken cancellationToken = default);
    Task StopAsync(CancellationToken cancellationToken = default);
}
