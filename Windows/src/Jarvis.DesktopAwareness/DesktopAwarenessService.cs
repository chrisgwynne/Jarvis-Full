using System.Diagnostics;
using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.DesktopAwareness.Interop;
using Microsoft.Extensions.Logging;

namespace Jarvis.DesktopAwareness;

/// <summary>
/// Polls the OS for foreground-app + idle state on a single timer.
/// Designed for &lt;1% CPU at 250ms cadence — no UIA tree walking, no screenshots.
/// </summary>
public sealed class DesktopAwarenessService : IDesktopAwarenessService
{
    private readonly IJarvisSettingsStore _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<DesktopAwarenessService>? _logger;
    private readonly object _gate = new();
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private DesktopSnapshot? _latest;

    public DesktopAwarenessService(
        IJarvisSettingsStore settings,
        IDiagnostics? diagnostics = null,
        ILogger<DesktopAwarenessService>? logger = null)
    {
        _settings = settings;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public DesktopSnapshot? Latest { get { lock (_gate) return _latest; } }
    public event EventHandler<DesktopSnapshot>? SnapshotChanged;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_loop is not null) return Task.CompletedTask;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _loop = Task.Run(() => RunAsync(_cts.Token));
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (_cts is null || _loop is null) return;
        _cts.Cancel();
        try { await _loop.ConfigureAwait(false); } catch { /* shutting down */ }
        _loop = null;
    }

    private async Task RunAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var awareness = _settings.Current.Awareness;
            var sw = Stopwatch.StartNew();
            try
            {
                var snapshot = Capture(awareness);
                if (HasChanged(_latest, snapshot))
                {
                    lock (_gate) _latest = snapshot;
                    SnapshotChanged?.Invoke(this, snapshot);
                }
                _diagnostics?.RecordMetric("awareness.lastPollMs", sw.Elapsed.TotalMilliseconds);
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(ex, "Awareness poll failed");
                _diagnostics?.Record(DiagnosticLevel.Warn, "awareness", "poll failed",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
            }

            try { await Task.Delay(Math.Max(50, awareness.PollIntervalMs), token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    private static DesktopSnapshot Capture(AwarenessSettings settings)
    {
        var hwnd = User32.GetForegroundWindow();
        var title = settings.TrackForegroundApp ? User32.ReadWindowTitle(hwnd) : string.Empty;
        var processName = settings.TrackForegroundApp ? TryGetProcessName(hwnd) : null;
        var bounds = User32.GetWindowRect(hwnd, out var rect)
            ? new Rect(rect.Left, rect.Top, rect.Right, rect.Bottom)
            : Rect.Empty;

        TimeSpan idle = TimeSpan.Zero;
        if (settings.TrackIdle)
        {
            var lii = new User32.LASTINPUTINFO { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<User32.LASTINPUTINFO>() };
            if (User32.GetLastInputInfo(ref lii))
            {
                var ticksNow = (uint)Environment.TickCount;
                idle = TimeSpan.FromMilliseconds(unchecked(ticksNow - lii.dwTime));
            }
        }

        return new DesktopSnapshot(
            CapturedAt: DateTimeOffset.UtcNow,
            ForegroundProcessName: processName,
            ForegroundWindowTitle: title,
            ForegroundWindowHandle: hwnd,
            ActiveMonitorIndex: User32.FindMonitorIndex(hwnd),
            ForegroundWindowBounds: bounds,
            UserIdleTime: idle,
            IsUserActive: idle < TimeSpan.FromSeconds(settings.IdleThresholdSeconds));
    }

    private static string? TryGetProcessName(nint hwnd)
    {
        if (hwnd == 0) return null;
        try
        {
            _ = User32.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == 0) return null;
            using var proc = Process.GetProcessById((int)pid);
            return proc.ProcessName;
        }
        catch
        {
            return null;
        }
    }

    private static bool HasChanged(DesktopSnapshot? prev, DesktopSnapshot next)
    {
        if (prev is null) return true;
        return prev.ForegroundWindowHandle != next.ForegroundWindowHandle
            || !string.Equals(prev.ForegroundWindowTitle, next.ForegroundWindowTitle, StringComparison.Ordinal)
            || prev.IsUserActive != next.IsUserActive;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _cts?.Dispose();
    }
}
