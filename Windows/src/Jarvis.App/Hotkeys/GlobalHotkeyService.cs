using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Hotkeys;

namespace Jarvis.App.Hotkeys;

/// <summary>
/// Win32 RegisterHotKey-backed implementation. Owns a message-only HwndSource so we
/// don't pollute the overlay's hwnd with WM_HOTKEY traffic.
///
/// Accelerators use the same string format as the JarvisSettings.Hotkeys section:
///   "Ctrl+Shift+J", "Alt+Space", etc. Modifiers: Ctrl, Alt, Shift, Win. Key: anything
///   System.Windows.Input.Key parses (single character, F1..F24, etc.).
/// </summary>
public sealed class GlobalHotkeyService : IHotkeyService, IDisposable
{
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    private const int WM_HOTKEY = 0x0312;
    private const int HWND_MESSAGE_INT = -3;

    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_SHIFT = 0x0004;
    private const uint MOD_WIN = 0x0008;
    private const uint MOD_NOREPEAT = 0x4000;

    private readonly IDiagnostics? _diagnostics;
    private readonly Dictionary<string, Registration> _registered = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<int, Action> _byId = new();
    private int _nextId = 1;
    private HwndSource? _source;
    private bool _initialized;

    private sealed record Registration(int Id, string Accelerator, Action Callback);

    public GlobalHotkeyService(IDiagnostics? diagnostics = null) => _diagnostics = diagnostics;

    public IReadOnlyDictionary<string, string> Registered =>
        _registered.ToDictionary(kv => kv.Key, kv => kv.Value.Accelerator);

    public bool Register(string name, string accelerator, Action callback)
    {
        EnsureInitialized();
        if (_source is null) return false;

        if (_registered.TryGetValue(name, out var existing))
        {
            UnregisterHotKey(_source.Handle, existing.Id);
            _byId.Remove(existing.Id);
            _registered.Remove(name);
        }

        if (!TryParse(accelerator, out var mods, out var vk))
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "hotkeys", "bad accelerator",
                new Dictionary<string, object?> { ["name"] = name, ["accelerator"] = accelerator });
            return false;
        }

        var id = _nextId++;
        if (!RegisterHotKey(_source.Handle, id, mods | MOD_NOREPEAT, vk))
        {
            var err = Marshal.GetLastWin32Error();
            _diagnostics?.Record(DiagnosticLevel.Warn, "hotkeys", "RegisterHotKey failed",
                new Dictionary<string, object?> { ["name"] = name, ["accelerator"] = accelerator, ["err"] = err });
            return false;
        }
        _registered[name] = new Registration(id, accelerator, callback);
        _byId[id] = callback;
        _diagnostics?.Record(DiagnosticLevel.Info, "hotkeys", "registered",
            new Dictionary<string, object?> { ["name"] = name, ["accelerator"] = accelerator });
        return true;
    }

    public bool Unregister(string name)
    {
        if (_source is null) return false;
        if (!_registered.Remove(name, out var reg)) return false;
        UnregisterHotKey(_source.Handle, reg.Id);
        _byId.Remove(reg.Id);
        return true;
    }

    private void EnsureInitialized()
    {
        if (_initialized) return;
        _initialized = true;
        var app = System.Windows.Application.Current ?? throw new InvalidOperationException("GlobalHotkeyService requires a WPF Application.");
        app.Dispatcher.Invoke(() =>
        {
            var parameters = new HwndSourceParameters("Jarvis.HotkeySink")
            {
                WindowStyle = 0,
                ExtendedWindowStyle = 0,
                ParentWindow = new IntPtr(HWND_MESSAGE_INT)
            };
            _source = new HwndSource(parameters);
            _source.AddHook(WndProc);
        });
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && _byId.TryGetValue(wParam.ToInt32(), out var cb))
        {
            try { cb(); }
            catch (Exception ex)
            {
                _diagnostics?.Record(DiagnosticLevel.Warn, "hotkeys", "callback threw",
                    new Dictionary<string, object?> { ["error"] = ex.Message });
            }
            handled = true;
        }
        return IntPtr.Zero;
    }

    internal static bool TryParse(string accelerator, out uint mods, out uint vk)
    {
        mods = 0; vk = 0;
        if (string.IsNullOrWhiteSpace(accelerator)) return false;
        var parts = accelerator.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Key? key = null;
        foreach (var raw in parts)
        {
            var p = raw.Replace(" ", "");
            switch (p.ToLowerInvariant())
            {
                case "ctrl": case "control": mods |= MOD_CONTROL; break;
                case "alt": mods |= MOD_ALT; break;
                case "shift": mods |= MOD_SHIFT; break;
                case "win": case "windows": case "meta": mods |= MOD_WIN; break;
                default:
                    if (key is not null) return false;
                    if (Enum.TryParse<Key>(p, ignoreCase: true, out var parsed)) { key = parsed; break; }
                    if (PunctuationToKey(p) is { } pk) { key = pk; break; }
                    return false;
            }
        }
        if (key is null) return false;
        vk = (uint)KeyInterop.VirtualKeyFromKey(key.Value);
        return mods != 0 && vk != 0;
    }

    private static Key? PunctuationToKey(string p) => p switch
    {
        "," => Key.OemComma,
        "." => Key.OemPeriod,
        "/" or "?" => Key.OemQuestion,
        ";" or ":" => Key.OemSemicolon,
        "'" or "\"" => Key.OemQuotes,
        "[" or "{" => Key.OemOpenBrackets,
        "]" or "}" => Key.OemCloseBrackets,
        "\\" or "|" => Key.OemBackslash,
        "-" or "_" => Key.OemMinus,
        "=" or "+" => Key.OemPlus,
        "`" or "~" => Key.OemTilde,
        _ => null
    };

    public void Dispose()
    {
        if (_source is not null)
        {
            foreach (var reg in _registered.Values) UnregisterHotKey(_source.Handle, reg.Id);
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
        _registered.Clear();
        _byId.Clear();
    }
}
