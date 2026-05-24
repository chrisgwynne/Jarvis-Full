using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Jarvis.App.Interop;

namespace Jarvis.App.Overlay;

/// <summary>
/// Some apps (full-screen games, security dialogs, screen sharing) can demote a topmost overlay.
/// We re-assert WS_EX_TOPMOST on a slow heartbeat. Cheap: one GetWindowLong + (rarely) one SetWindowPos.
/// </summary>
public sealed class TopmostGuard : IDisposable
{
    [DllImport("user32.dll")] private static extern int GetWindowLong(nint h, int n);

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOPMOST = 0x00000008;

    private readonly Window _window;
    private readonly DispatcherTimer _timer;

    public TopmostGuard(Window window, TimeSpan? interval = null)
    {
        _window = window;
        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = interval ?? TimeSpan.FromSeconds(4)
        };
        _timer.Tick += OnTick;
    }

    public void Start() => _timer.Start();
    public void Stop() => _timer.Stop();

    private void OnTick(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(_window).Handle;
        if (hwnd == 0) return;
        var ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        if ((ex & WS_EX_TOPMOST) != 0) return;
        OverlayInterop.ReassertTopmost(_window);
    }

    public void Dispose() => _timer.Stop();
}
