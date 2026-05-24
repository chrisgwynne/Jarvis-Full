using System.Runtime.InteropServices;

namespace Jarvis.App.Interop;

/// <summary>
/// Win32 plumbing for cursor / monitor / window-positioning math used by the Pebble
/// follower. Kept separate from <see cref="OverlayInterop"/> because the follower needs
/// per-monitor DPI lookup, which the overlay-style helpers don't.
/// </summary>
internal static class CursorAnchorInterop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern nint MonitorFromPoint(POINT pt, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern nint MonitorFromWindow(nint hwnd, uint dwFlags);

    [DllImport("Shcore.dll")]
    public static extern int GetDpiForMonitor(nint hmonitor, MDT dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetMonitorInfo(nint hMonitor, ref MONITORINFO lpmi);

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public enum MDT { Effective = 0, Angular = 1, Raw = 2 }

    public const uint MONITOR_DEFAULTTONEAREST = 2;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_NOREDRAW = 0x0008;

    /// <summary>Read the cursor's monitor effective DPI. Returns 96 if anything fails.</summary>
    public static double GetCursorScale(out POINT cursor)
    {
        if (!GetCursorPos(out cursor)) { cursor = default; return 1.0; }
        try
        {
            var mon = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
            if (mon == 0) return 1.0;
            if (GetDpiForMonitor(mon, MDT.Effective, out var dpiX, out _) == 0 && dpiX > 0)
                return dpiX / 96.0;
        }
        catch { /* GetDpiForMonitor not available on pre-8.1 */ }
        return 1.0;
    }

    /// <summary>Working area of the monitor the cursor is on, in physical pixels.</summary>
    public static RECT GetCursorMonitorWorkArea(POINT cursor)
    {
        var mon = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (mon != 0 && GetMonitorInfo(mon, ref mi)) return mi.rcWork;
        return new RECT { Left = 0, Top = 0, Right = int.MaxValue, Bottom = int.MaxValue };
    }
}
