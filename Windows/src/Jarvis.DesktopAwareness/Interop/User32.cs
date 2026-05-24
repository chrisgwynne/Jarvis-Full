using System.Runtime.InteropServices;
using System.Text;

namespace Jarvis.DesktopAwareness.Interop;

/// <summary>Centralised P/Invoke surface. Keep allocation off the hot path.</summary>
internal static partial class User32
{
    [LibraryImport("user32.dll")]
    internal static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial int GetWindowText(nint hWnd, [Out] char[] lpString, int nMaxCount);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextLengthW")]
    internal static partial int GetWindowTextLength(nint hWnd);

    [LibraryImport("user32.dll")]
    internal static partial uint GetWindowThreadProcessId(nint hWnd, out uint lpdwProcessId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetWindowRect(nint hWnd, out RECT lpRect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out POINT lpPoint);

    [LibraryImport("user32.dll")]
    internal static partial nint MonitorFromWindow(nint hwnd, uint dwFlags);

    [LibraryImport("user32.dll")]
    internal static partial nint MonitorFromPoint(POINT pt, uint dwFlags);

    [LibraryImport("user32.dll")]
    internal static partial int GetSystemMetrics(int nIndex);

    internal const uint MONITOR_DEFAULTTONEAREST = 0x00000002;

    internal const int SM_CMONITORS = 80;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    internal delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    internal static int FindMonitorIndex(nint hwnd)
    {
        if (hwnd == 0) return 0;
        var target = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (target == IntPtr.Zero) return 0;
        var handles = new List<IntPtr>(4);
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref RECT _, IntPtr _) =>
        {
            handles.Add(h);
            return true;
        }, IntPtr.Zero);
        var idx = handles.IndexOf(target);
        return idx >= 0 ? idx : 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT
    {
        public int X, Y;
    }

    internal static string ReadWindowTitle(nint hWnd)
    {
        var len = GetWindowTextLength(hWnd);
        if (len <= 0) return string.Empty;
        var buffer = new char[len + 1];
        var copied = GetWindowText(hWnd, buffer, buffer.Length);
        return copied > 0 ? new string(buffer, 0, copied) : string.Empty;
    }
}
