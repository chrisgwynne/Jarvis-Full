using System.Runtime.InteropServices;

namespace Jarvis.App.Interop;

internal static class CursorInterop
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    public static (int X, int Y) GetCursor()
    {
        return GetCursorPos(out var pt) ? (pt.X, pt.Y) : (0, 0);
    }
}
