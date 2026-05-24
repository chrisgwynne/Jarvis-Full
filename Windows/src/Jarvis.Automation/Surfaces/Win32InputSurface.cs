using System.Runtime.InteropServices;
using System.Windows.Input;
using Jarvis.Core.Automation;

namespace Jarvis.Automation.Surfaces;

/// <summary>
/// SendInput-backed input surface. Synthesises keyboard and mouse events.
///
/// Notes:
///   - Unicode typing uses KEYBDINPUT.KEYEVENTF_UNICODE so we don't care about layouts.
///   - Shortcuts parse via the same accelerator grammar as GlobalHotkeyService.
///   - All methods return null on success or an error string on failure (matches the
///     contract of <see cref="IInputAutomationSurface"/>).
///   - Synthesised input cannot reach UIPI-elevated windows (admin-elevated apps) — the
///     call succeeds silently but no input is delivered. We can't reliably detect that
///     here; the audit log will say "Succeeded" while the action had no effect. Document
///     this as a known limitation.
/// </summary>
public sealed class Win32InputSurface : IInputAutomationSurface
{
    public Task<string?> SendShortcutAsync(string accelerator, CancellationToken cancellationToken)
    {
        if (!TryParseAccelerator(accelerator, out var mods, out var key))
            return Task.FromResult<string?>($"unparsable accelerator: {accelerator}");
        var keys = new List<ushort>();
        if (mods.HasFlag(Mod.Ctrl)) keys.Add((ushort)KeyInterop.VirtualKeyFromKey(Key.LeftCtrl));
        if (mods.HasFlag(Mod.Shift)) keys.Add((ushort)KeyInterop.VirtualKeyFromKey(Key.LeftShift));
        if (mods.HasFlag(Mod.Alt)) keys.Add((ushort)KeyInterop.VirtualKeyFromKey(Key.LeftAlt));
        if (mods.HasFlag(Mod.Win)) keys.Add((ushort)KeyInterop.VirtualKeyFromKey(Key.LWin));
        keys.Add((ushort)KeyInterop.VirtualKeyFromKey(key));
        var inputs = new INPUT[keys.Count * 2];
        for (var i = 0; i < keys.Count; i++) inputs[i] = KeyDown(keys[i]);
        for (var i = 0; i < keys.Count; i++) inputs[keys.Count + i] = KeyUp(keys[keys.Count - 1 - i]);
        return Task.FromResult(Send(inputs));
    }

    public Task<string?> TypeAsync(string text, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(text)) return Task.FromResult<string?>(null);
        var inputs = new INPUT[text.Length * 2];
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            inputs[2 * i] = UnicodeKey(ch, up: false);
            inputs[2 * i + 1] = UnicodeKey(ch, up: true);
        }
        return Task.FromResult(Send(inputs));
    }

    public async Task<string?> PasteAsync(string text, CancellationToken cancellationToken)
    {
        if (text is null) return "null text";
        string? saved = null;
        try
        {
            // Best-effort: stash whatever's on the clipboard so paste is reversible.
            saved = System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null);
            System.Windows.Application.Current?.Dispatcher.Invoke(() => System.Windows.Clipboard.SetText(text));
            await Task.Delay(40, cancellationToken).ConfigureAwait(false); // let the clipboard listener settle
            var err = await SendShortcutAsync("Ctrl+V", cancellationToken).ConfigureAwait(false);
            if (err is not null) return err;
            await Task.Delay(60, cancellationToken).ConfigureAwait(false);
            return null;
        }
        catch (Exception ex) { return ex.Message; }
        finally
        {
            if (saved is not null)
                try { System.Windows.Application.Current?.Dispatcher.Invoke(() => System.Windows.Clipboard.SetText(saved)); }
                catch { /* best effort */ }
        }
    }

    public Task<string?> PressKeyAsync(string key, CancellationToken cancellationToken)
    {
        if (!Enum.TryParse<Key>(key, ignoreCase: true, out var k))
            return Task.FromResult<string?>($"unknown key: {key}");
        var vk = (ushort)KeyInterop.VirtualKeyFromKey(k);
        return Task.FromResult(Send(new[] { KeyDown(vk), KeyUp(vk) }));
    }

    public Task<string?> MoveCursorAsync(int x, int y, CancellationToken cancellationToken)
    {
        if (!SetCursorPos(x, y)) return Task.FromResult<string?>($"SetCursorPos failed: {Marshal.GetLastWin32Error()}");
        return Task.FromResult<string?>(null);
    }

    public Task<string?> ClickAsync(int x, int y, MouseButtonKind button, int count, CancellationToken cancellationToken)
    {
        if (!SetCursorPos(x, y)) return Task.FromResult<string?>($"SetCursorPos failed: {Marshal.GetLastWin32Error()}");
        var (down, up) = button switch
        {
            MouseButtonKind.Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
            MouseButtonKind.Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            MouseButtonKind.Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
            _ => (0u, 0u)
        };
        var inputs = new INPUT[count * 2];
        for (var i = 0; i < count; i++)
        {
            inputs[2 * i] = MouseEvent(down);
            inputs[2 * i + 1] = MouseEvent(up);
        }
        return Task.FromResult(Send(inputs));
    }

    public Task<string?> ScrollAsync(int dx, int dy, CancellationToken cancellationToken)
    {
        var inputs = new List<INPUT>();
        if (dy != 0) inputs.Add(MouseEvent(MOUSEEVENTF_WHEEL, mouseData: dy));
        if (dx != 0) inputs.Add(MouseEvent(MOUSEEVENTF_HWHEEL, mouseData: dx));
        return Task.FromResult(Send(inputs.ToArray()));
    }

    // ── P/Invoke ────────────────────────────────────────────────────────────

    [Flags] private enum Mod { None = 0, Ctrl = 1, Shift = 2, Alt = 4, Win = 8 }

    private static bool TryParseAccelerator(string accelerator, out Mod mods, out Key key)
    {
        mods = Mod.None;
        key = Key.None;
        if (string.IsNullOrWhiteSpace(accelerator)) return false;
        foreach (var raw in accelerator.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl": case "control": mods |= Mod.Ctrl; break;
                case "alt": mods |= Mod.Alt; break;
                case "shift": mods |= Mod.Shift; break;
                case "win": case "windows": case "meta": mods |= Mod.Win; break;
                default:
                    if (key != Key.None) return false;
                    if (!Enum.TryParse(raw, ignoreCase: true, out key)) return false;
                    break;
            }
        }
        return key != Key.None;
    }

    private static string? Send(INPUT[] inputs)
    {
        if (inputs.Length == 0) return null;
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        return sent == inputs.Length ? null : $"SendInput sent {sent}/{inputs.Length} (err {Marshal.GetLastWin32Error()})";
    }

    private const int INPUT_KEYBOARD = 1;
    private const int INPUT_MOUSE = 0;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x01000;

    private static INPUT KeyDown(ushort vk) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk } }
    };

    private static INPUT KeyUp(ushort vk) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYEVENTF_KEYUP } }
    };

    private static INPUT UnicodeKey(char c, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = c,
                dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0)
            }
        }
    };

    private static INPUT MouseEvent(uint flags, int mouseData = 0) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion { mi = new MOUSEINPUT { dwFlags = flags, mouseData = mouseData } }
    };

    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int X, int Y);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public int type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy, mouseData;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }
}
