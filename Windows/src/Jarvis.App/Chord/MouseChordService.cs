using Jarvis.App.Interop;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;

namespace Jarvis.App.Chord;

/// <summary>
/// Wires the WH_MOUSE_LL hook to the middle-mouse-button "open Pebble menu" gesture.
///
/// Why middle button: pressing left+right together (the original P6.1 chord) reliably
/// collides with Windows' right-click context menu — it fires on right-button-down
/// regardless of any subsequent left press. Middle button is unused by most apps for
/// anything other than scroll-wheel-click, so it's a clean, single-event trigger.
///
/// Debounce: ignore middle-down while the button is still held (no auto-repeat fires),
/// and ignore down events that arrive within 200 ms of the previous fire (protects
/// against double-press bounces on some mice).
///
/// The hook never swallows mouse events — every callback still calls CallNextHookEx —
/// so legacy "scroll-wheel-click to paste" / "open link in new tab" still works.
/// </summary>
public sealed class MouseChordService : IDisposable
{
    private static readonly TimeSpan FireDebounce = TimeSpan.FromMilliseconds(200);

    private readonly LowLevelMouseHook _hook = new();
    private readonly Func<MouseChordSettings> _settings;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();
    private bool _installed;
    private bool _middleDown;
    private DateTimeOffset _lastFireAt = DateTimeOffset.MinValue;
    private int _lastFireX, _lastFireY;

    /// <summary>Raised when the gesture fires. Args are cursor coordinates in physical
    /// pixels at the moment of the press.</summary>
    public event EventHandler<(int X, int Y)>? ChordFired;

    public MouseChordService(
        Func<MouseChordSettings> settings,
        IDiagnostics? diagnostics = null,
        Func<JarvisSettings>? allSettings = null)
    {
        _settings = settings;
        _diagnostics = diagnostics;
        _hook.Event += OnHookEvent;
    }

    public void Start()
    {
        if (_installed) return;
        if (!_settings().EnableMouseChordMenu) return;
        _hook.Install();
        _installed = true;
        _diagnostics?.Record(DiagnosticLevel.Info, "chord", "service started",
            new Dictionary<string, object?> { ["trigger"] = "middle-mouse-button" });
    }

    private void OnHookEvent(object? sender, MouseHookEventArgs e)
    {
        if (!_settings().EnableMouseChordMenu) return;

        switch (e.Message)
        {
            case LowLevelMouseHook.WM_MBUTTONDOWN:
                OnMiddleDown(e.X, e.Y);
                break;
            case LowLevelMouseHook.WM_MBUTTONUP:
                lock (_gate) _middleDown = false;
                break;
        }
    }

    private void OnMiddleDown(int x, int y)
    {
        bool fire;
        DateTimeOffset now = DateTimeOffset.UtcNow;
        lock (_gate)
        {
            if (_middleDown) return;            // auto-repeat / hold — never fire twice
            if (now - _lastFireAt < FireDebounce) return;
            _middleDown = true;
            _lastFireAt = now;
            _lastFireX = x; _lastFireY = y;
            fire = true;
        }
        if (fire)
        {
            _diagnostics?.Record(DiagnosticLevel.Info, "chord", "detected",
                new Dictionary<string, object?>
                {
                    ["trigger"] = "middle",
                    ["x"] = x,
                    ["y"] = y
                });
            ChordFired?.Invoke(this, (x, y));
        }
    }

    public void Dispose()
    {
        _hook.Dispose();
    }
}
