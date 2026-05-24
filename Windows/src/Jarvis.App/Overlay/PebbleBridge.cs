using System.Text.Json;
using System.Windows.Threading;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Presence;
using Jarvis.Core.State;
using Microsoft.Web.WebView2.Wpf;

namespace Jarvis.App.Overlay;

/// <summary>
/// One-way bridge from .NET to the WebView2 renderer.
/// Pushes:
///   - state transitions (priority-resolved by PebbleStateMachine)
///   - HUD on/off
///   - perf metrics (1Hz when HUD is on)
/// Never receives — keeps the trust boundary clean.
/// </summary>
public sealed class PebbleBridge : IDisposable
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly WebView2 _webView;
    private readonly PebbleStateMachine _machine;
    private readonly IDiagnostics _diagnostics;
    private readonly DispatcherTimer _metricsTimer;
    private bool _webReady;
    private bool _hudOn;

    public PebbleBridge(WebView2 webView, PebbleStateMachine machine, IDiagnostics diagnostics)
    {
        _webView = webView;
        _machine = machine;
        _diagnostics = diagnostics;
        _metricsTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _metricsTimer.Tick += (_, _) => PushMetrics();
    }

    public bool HudOn => _hudOn;

    public void Attach()
    {
        _webView.CoreWebView2InitializationCompleted += (_, e) =>
        {
            if (!e.IsSuccess) return;
            _webReady = true;
            PushState(_machine.Current);
            PushHud(_hudOn);
        };
        _machine.Transitioned += (_, t) =>
        {
            PushState(t.To);
            // State-transition timing surfaces in diagnostics so we can see if any state is
            // sticking longer than expected (e.g. Reconnecting > 30s = bridge issue).
            _diagnostics.Record(DiagnosticLevel.Debug, "pebble.state", "transition",
                new Dictionary<string, object?>
                {
                    ["from"] = t.From.ToString(),
                    ["to"] = t.To.ToString(),
                    ["reason"] = t.Reason,
                    ["dwellMs"] = (long)t.DwellTime.TotalMilliseconds
                });
        };
    }

    public void SetHud(bool on)
    {
        _hudOn = on;
        PushHud(on);
        if (on) _metricsTimer.Start(); else _metricsTimer.Stop();
    }

    /// <summary>Fire a one-shot wake ripple. The renderer adds a CSS class for ~800ms
    /// then drops it; we don't need to push a "wake off" message.</summary>
    public void PushWakeRipple() => Post(new { type = "wake" });

    /// <summary>Fire an interruption flash + force immediate listening transition feel.
    /// The renderer collapses the speaking waveform inside one paint.</summary>
    public void PushInterruption() => Post(new { type = "interruption" });

    /// <summary>Push a quantised amplitude bucket for audio-reactive visualisation.
    /// Sending the bucket name (Low/Mid/High) rather than the raw value means the
    /// renderer flips a CSS class instead of forcing layout each frame.</summary>
    public void PushAmplitude(AmplitudeSmoother.Bucket bucket) =>
        Post(new { type = "amplitude", value = bucket.ToString().ToLowerInvariant() });

    /// <summary>Push the current attention mode + intensity. Renderer uses these to dial
    /// breathing rate and halo opacity without changing the discrete pebble state.</summary>
    public void PushAttention(AttentionMode mode, double intensity) =>
        Post(new { type = "attention", value = new { mode = mode.ToString().ToLowerInvariant(), intensity } });

    /// <summary>Toggle the renderer's menu-open hint. Pebble adds a subtle focus glow so
    /// the user sees that the chord registered, without changing the discrete state.</summary>
    public void PushMenuOpen(bool open) =>
        Post(new { type = "menu", value = open });

    private void PushState(PebbleState s) =>
        Post(new { type = "state", value = s.ToString() });

    private void PushHud(bool on) =>
        Post(new { type = "hud", value = on });

    private void PushMetrics()
    {
        if (!_hudOn) return;
        _diagnostics.Metrics.TryGetValue("cpu.percent", out var cpu);
        _diagnostics.Metrics.TryGetValue("memory.workingSetMb", out var mem);
        Post(new { type = "metrics", value = new { cpu, mem } });
    }

    private void Post(object payload)
    {
        if (!_webReady || _webView.CoreWebView2 is null) return;
        try
        {
            _webView.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(payload, JsonOpts));
        }
        catch
        {
            // WebView shutting down — drop silently
        }
    }

    public void Dispose() => _metricsTimer.Stop();
}
