using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Jarvis.App.Interop;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Settings;

namespace Jarvis.App.Overlay;

/// <summary>
/// Drives the overlay window position toward the cursor each frame.
///
/// Coordinate system: we live entirely in *physical pixels* and call
/// <see cref="CursorAnchorInterop.SetWindowPos"/> directly. WPF's <c>Window.Left</c> /
/// <c>Top</c> in per-monitor DPI v2 are reinterpreted as the window crosses monitors,
/// which made it impossible to land the pebble adjacent to the cursor on mixed-DPI
/// setups (~5 cm drift on 150% scaling). SetWindowPos takes physical pixels and
/// doesn't care about WPF DPI bookkeeping.
///
/// Offset is in DIPs (CSS-like) and scaled to the cursor monitor's effective DPI on each
/// frame — so the pebble feels the same distance from the cursor at 100%, 150%, and
/// 200% scaling.
///
/// Easing: a critically-damped exponential lerp toward the target each frame. With the
/// default easing of 0.18 the pebble catches up within ~5 frames (~80 ms) — fast enough
/// to feel tethered without overshoot.
/// </summary>
public sealed class CursorFollower : IDisposable
{
    private readonly Window _window;
    private readonly IJarvisSettingsStore _settings;
    private readonly IDiagnostics? _diagnostics;
    private nint _hwnd;
    private double _xPhys, _yPhys;
    private bool _initialized;
    private int _frameCount;
    private DateTimeOffset _lastDebugAt;
    private int _prevCursorX, _prevCursorY;
    private DateTimeOffset _prevFrameAt;
    private double _smoothedVelocityPxPerSec;

    // Last-known telemetry for the optional debug HUD.
    public int LastCursorX { get; private set; }
    public int LastCursorY { get; private set; }
    public int LastTargetX { get; private set; }
    public int LastTargetY { get; private set; }
    public double LastScale { get; private set; } = 1.0;
    public double LastEaseDelta { get; private set; }
    /// <summary>Latest smoothed cursor speed in physical pixels per second. Surfaces for
    /// the AttentionModel + bridge diagnostics.</summary>
    public double LastCursorVelocity => _smoothedVelocityPxPerSec;

    public CursorFollower(Window window, IJarvisSettingsStore settings, IDiagnostics? diagnostics = null)
    {
        _window = window;
        _settings = settings;
        _diagnostics = diagnostics;
    }

    public void Start()
    {
        _hwnd = new WindowInteropHelper(_window).Handle;
        CompositionTarget.Rendering += OnFrame;
    }

    public void Stop()
    {
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var pebble = _settings.Current.Pebble;
        if (!pebble.FollowCursor) return;
        if (_hwnd == 0) _hwnd = new WindowInteropHelper(_window).Handle;
        if (_hwnd == 0) return;

        // Step 1: read cursor in physical pixels + look up the cursor monitor's DPI scale.
        var scale = CursorAnchorInterop.GetCursorScale(out var cursor);
        LastCursorX = cursor.X; LastCursorY = cursor.Y; LastScale = scale;

        // Step 2: settings offset is in DIPs; convert to physical pixels using the cursor
        // monitor's scale (not the window's — the window may be on a differently-scaled
        // monitor while it travels).
        var offsetPx = (int)Math.Round(pebble.CursorOffsetX * scale);
        var offsetPy = (int)Math.Round(pebble.CursorOffsetY * scale);

        // Step 3: pebble width/height — settings.Size is also in DIPs.
        var widthPx  = (int)Math.Round(pebble.Size * scale);
        var heightPx = (int)Math.Round(pebble.Size * scale);

        // Anchor point: cursor + offset. The cursor hotspot is the top-left of the arrow
        // by Win32 convention, so adding the offset puts the pebble down-right of the
        // arrow tip — visually adjacent.
        var targetX = cursor.X + offsetPx;
        var targetY = cursor.Y + offsetPy;
        LastTargetX = targetX; LastTargetY = targetY;

        // Step 4: clamp to cursor-monitor work area, accounting for pebble footprint.
        var work = CursorAnchorInterop.GetCursorMonitorWorkArea(cursor);
        targetX = Math.Clamp(targetX, work.Left, Math.Max(work.Left, work.Right - widthPx));
        targetY = Math.Clamp(targetY, work.Top, Math.Max(work.Top, work.Bottom - heightPx));

        // Step 5: velocity-aware ease. Slow cursor → softer drift (more lag, calmer feel).
        // Fast cursor → snap-tight (less lag, less perceived disconnection during gestures).
        // Velocity smoothed with a short EMA so a single jittery frame doesn't whip the ease.
        var nowUtc = DateTimeOffset.UtcNow;
        if (!_initialized)
        {
            _xPhys = targetX; _yPhys = targetY;
            _initialized = true;
            LastEaseDelta = 0;
            _prevCursorX = cursor.X; _prevCursorY = cursor.Y;
            _prevFrameAt = nowUtc;
        }
        else
        {
            var dtSec = Math.Max(0.001, (nowUtc - _prevFrameAt).TotalSeconds);
            var instantaneousVel = Math.Sqrt(
                (cursor.X - _prevCursorX) * (cursor.X - _prevCursorX) +
                (cursor.Y - _prevCursorY) * (cursor.Y - _prevCursorY)) / dtSec;
            // EMA ~5-frame window so noise doesn't drive ease oscillation.
            _smoothedVelocityPxPerSec += (instantaneousVel - _smoothedVelocityPxPerSec) * 0.35;
            _prevCursorX = cursor.X; _prevCursorY = cursor.Y;
            _prevFrameAt = nowUtc;

            // Map velocity 0..2000 px/s to ease 0.18..0.55. At fast cursor speeds, ease
            // approaches 0.55 (≈3-frame convergence). At rest, ease stays at the configured
            // base value (default 0.18 ≈ smooth trail).
            var baseEase = Math.Clamp(pebble.FollowEasing, 0.05, 0.5);
            var velocityFactor = Math.Min(1.0, _smoothedVelocityPxPerSec / 2000.0);
            var ease = baseEase + (0.55 - baseEase) * velocityFactor;
            var dx = (targetX - _xPhys) * ease;
            var dy = (targetY - _yPhys) * ease;
            _xPhys += dx; _yPhys += dy;
            LastEaseDelta = Math.Abs(dx) + Math.Abs(dy);
        }

        // Step 6: position the window in physical pixels. SetWindowPos with SWP_NOSIZE
        // doesn't touch dimensions; we still want to update the WPF Width/Height to match
        // the per-monitor scaled footprint so the bitmap doesn't get blurred by WPF's own
        // DIP scaling when the monitor changes.
        const uint flags = CursorAnchorInterop.SWP_NOSIZE |
                           CursorAnchorInterop.SWP_NOZORDER |
                           CursorAnchorInterop.SWP_NOACTIVATE |
                           CursorAnchorInterop.SWP_NOREDRAW;
        CursorAnchorInterop.SetWindowPos(_hwnd, 0, (int)Math.Round(_xPhys), (int)Math.Round(_yPhys), 0, 0, flags);

        // Anchor-debug: emit one diagnostics line per second when enabled.
        if (pebble.AnchorDebug)
        {
            var now = DateTimeOffset.UtcNow;
            if (++_frameCount > 30 && now - _lastDebugAt > TimeSpan.FromSeconds(1))
            {
                _frameCount = 0; _lastDebugAt = now;
                _diagnostics?.Record(DiagnosticLevel.Debug, "pebble.anchor", "frame",
                    new Dictionary<string, object?>
                    {
                        ["cursor"] = $"{LastCursorX},{LastCursorY}",
                        ["target"] = $"{LastTargetX},{LastTargetY}",
                        ["window"] = $"{(int)Math.Round(_xPhys)},{(int)Math.Round(_yPhys)}",
                        ["scale"] = LastScale,
                        ["easeDelta"] = LastEaseDelta
                    });
            }
        }
    }

    public void Dispose() => Stop();
}
