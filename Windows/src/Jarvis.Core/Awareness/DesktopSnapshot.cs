namespace Jarvis.Core.Awareness;

/// <summary>
/// One immutable observation of the desktop. The Awareness service emits these on a
/// throttled cadence; downstream consumers (state machine, semantic layer, diagnostics)
/// react without re-querying Win32.
/// </summary>
public sealed record DesktopSnapshot(
    DateTimeOffset CapturedAt,
    string? ForegroundProcessName,
    string? ForegroundWindowTitle,
    nint ForegroundWindowHandle,
    int ActiveMonitorIndex,
    Rect ForegroundWindowBounds,
    TimeSpan UserIdleTime,
    bool IsUserActive);

public readonly record struct Rect(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool IsEmpty => Width <= 0 || Height <= 0;
    public static Rect Empty => new(0, 0, 0, 0);
}
