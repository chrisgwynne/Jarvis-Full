using System.Runtime.InteropServices;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Shared Win32 P/Invoke declarations for the tool layer.
/// </summary>
internal static class Win32Helpers
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint hWnd);

    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetWindowRect(nint hwnd, out RECT rect);

    [DllImport("user32.dll")]
    internal static extern nint SendMessage(nint hWnd, int msg, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public int Width  => Right - Left;
        public int Height => Bottom - Top;
    }

    internal const int WM_APPCOMMAND = 0x319;
    internal const long APPCOMMAND_VOLUME_MUTE = 8;
    internal const long APPCOMMAND_VOLUME_DOWN = 9;
    internal const long APPCOMMAND_VOLUME_UP   = 10;
}
