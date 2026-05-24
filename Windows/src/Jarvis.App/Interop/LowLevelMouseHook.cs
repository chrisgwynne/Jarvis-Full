using System.Runtime.InteropServices;

namespace Jarvis.App.Interop;

/// <summary>
/// Win32 WH_MOUSE_LL global mouse hook. Used by the mouse-chord service to observe
/// left+right button presses without owning a window.
///
/// CRITICAL: the callback ALWAYS calls <see cref="CallNextHookEx"/> with the unchanged
/// wParam/lParam — we never swallow events. Normal left/right clicks must keep working;
/// the chord is purely additive.
///
/// The hook callback runs on whichever thread installed the hook, and that thread must
/// have a message pump. In a WPF app, installing from the UI thread is the simplest
/// reliable path.
/// </summary>
internal sealed class LowLevelMouseHook : IDisposable
{
    private const int WH_MOUSE_LL = 14;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_LBUTTONUP   = 0x0202;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_RBUTTONUP   = 0x0205;
    public const int WM_MBUTTONDOWN = 0x0207;
    public const int WM_MBUTTONUP   = 0x0208;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public nint dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x, y; }

    private delegate nint HookProc(int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookEx(int idHook, HookProc lpfn, nint hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(nint hhk);
    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern nint GetModuleHandle(string? lpModuleName);

    // Keep the delegate alive — otherwise the GC will collect it and Windows will
    // call into freed memory with predictably catastrophic results.
    private readonly HookProc _proc;
    private nint _hookId;

    public event EventHandler<MouseHookEventArgs>? Event;

    public LowLevelMouseHook()
    {
        _proc = OnHook;
    }

    public void Install()
    {
        if (_hookId != 0) return;
        var hMod = GetModuleHandle(System.Diagnostics.Process.GetCurrentProcess().MainModule?.ModuleName);
        _hookId = SetWindowsHookEx(WH_MOUSE_LL, _proc, hMod, 0);
        if (_hookId == 0)
            throw new InvalidOperationException($"SetWindowsHookEx(WH_MOUSE_LL) failed: {Marshal.GetLastWin32Error()}");
    }

    private nint OnHook(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0)
        {
            var msg = wParam.ToInt32();
            if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP ||
                msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP ||
                msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP)
            {
                MSLLHOOKSTRUCT data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
                try
                {
                    Event?.Invoke(this, new MouseHookEventArgs(msg, data.pt.x, data.pt.y));
                }
                catch
                {
                    // Never let a subscriber exception leave the hook callback — Windows would
                    // unhook us and the chord would silently die.
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hookId != 0)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = 0;
        }
    }
}

internal sealed record MouseHookEventArgs(int Message, int X, int Y);
