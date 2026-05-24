using System.Diagnostics;
using System.Runtime.InteropServices;
using Jarvis.Core.Automation;

namespace Jarvis.Automation.Surfaces;

public sealed class Win32WindowSurface : IWindowAutomationSurface
{
    public Task<string?> FocusAsync(string process, string? titleSubstring, CancellationToken cancellationToken)
    {
        var hwnd = FindByProcess(process, titleSubstring);
        if (hwnd == IntPtr.Zero) return Task.FromResult<string?>($"no visible window for process '{process}'");
        return Task.FromResult(BringToFront(hwnd));
    }

    public Task<string?> SwitchAppAsync(string process, CancellationToken cancellationToken) =>
        FocusAsync(process, null, cancellationToken);

    public Task<string?> MoveAsync(IntPtr hwnd, int x, int y, CancellationToken cancellationToken)
    {
        if (!GetWindowRect(hwnd, out var r)) return Task.FromResult<string?>("GetWindowRect failed");
        var w = r.Right - r.Left;
        var h = r.Bottom - r.Top;
        return Task.FromResult(MoveOrSize(hwnd, x, y, w, h));
    }

    public Task<string?> ResizeAsync(IntPtr hwnd, int width, int height, CancellationToken cancellationToken)
    {
        if (!GetWindowRect(hwnd, out var r)) return Task.FromResult<string?>("GetWindowRect failed");
        return Task.FromResult(MoveOrSize(hwnd, r.Left, r.Top, width, height));
    }

    public Task<string?> SetStateAsync(IntPtr hwnd, WindowState state, CancellationToken cancellationToken)
    {
        var cmd = state switch
        {
            WindowState.Minimized => SW_MINIMIZE,
            WindowState.Maximized => SW_MAXIMIZE,
            _ => SW_RESTORE
        };
        return Task.FromResult(ShowWindow(hwnd, cmd) ? null : "ShowWindow returned false");
    }

    private static string? MoveOrSize(IntPtr hwnd, int x, int y, int w, int h)
    {
        if (!SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE))
            return $"SetWindowPos failed: {Marshal.GetLastWin32Error()}";
        return null;
    }

    private static string? BringToFront(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        return SetForegroundWindow(hwnd) ? null : "SetForegroundWindow returned false";
    }

    private static IntPtr FindByProcess(string process, string? titleSubstring)
    {
        IntPtr found = IntPtr.Zero;
        foreach (var proc in Process.GetProcessesByName(StripExe(process)))
        {
            using (proc)
            {
                if (proc.MainWindowHandle != IntPtr.Zero && IsWindowVisible(proc.MainWindowHandle))
                {
                    if (titleSubstring is null || proc.MainWindowTitle.Contains(titleSubstring, StringComparison.OrdinalIgnoreCase))
                    {
                        found = proc.MainWindowHandle;
                        break;
                    }
                }
            }
        }
        return found;
    }

    private static string StripExe(string name) =>
        name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;

    // ── P/Invoke ────────────────────────────────────────────────────────────

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }

    private const int SW_MINIMIZE = 6;
    private const int SW_MAXIMIZE = 3;
    private const int SW_RESTORE = 9;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
}
