using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Guidance;

/// <summary>
/// Asks the extension for visible interactive elements via the <c>listTargets</c>
/// bridge command, then maps each CSS-pixel rect to real screen pixels using the
/// viewport metadata the extension reports back.
///
/// Preferred path (extension v0.3+ returns a Viewport):
///     screenX = viewport.ScreenX + cssX * dpr
///     screenY = viewport.ScreenY + cssY * dpr
/// <see cref="BrowserDomTarget.X"/>/<see cref="BrowserDomTarget.Y"/> come from
/// <c>getBoundingClientRect()</c> — already viewport-relative post-scroll — so no
/// scroll math is needed in the rect itself.
///
/// Fallback (older extension): heuristic 104 px chrome offset on top of the
/// foreground window. Still works at 1× DPR but is less accurate.
/// </summary>
public sealed class BrowserDomTargetSource : IUiTargetSource
{
    private static readonly TimeSpan ListTimeout = TimeSpan.FromSeconds(3);

    private readonly IBrowserCommandSurface _surface;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<BrowserDomTargetSource>? _logger;

    public BrowserDomTargetSource(
        IBrowserCommandSurface surface,
        IDiagnostics? diagnostics = null,
        ILogger<BrowserDomTargetSource>? logger = null)
    {
        _surface = surface;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public TargetSource Source => TargetSource.BrowserDom;

    public async Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext context, CancellationToken cancellationToken)
    {
        if (!context.BrowserConnected || !_surface.IsAvailable) return Array.Empty<UiTarget>();
        try
        {
            var ack = await _surface.SendWithAckAsync(new BrowserCommand("listTargets"), ListTimeout, cancellationToken).ConfigureAwait(false);
            if (!ack.Completed || ack.Targets is null)
            {
                _diagnostics?.Record(DiagnosticLevel.Debug, "guidance.browser", "no targets",
                    new Dictionary<string, object?> { ["error"] = ack.Error });
                return Array.Empty<UiTarget>();
            }
            return ConvertTargets(ack.Targets, ack.Viewport, context.ForegroundWindowBounds, context.ForegroundProcess);
        }
        catch (Exception ex)
        {
            _logger?.LogDebug(ex, "Browser-DOM discovery failed");
            return Array.Empty<UiTarget>();
        }
    }

    internal static IReadOnlyList<UiTarget> ConvertTargets(
        IReadOnlyList<BrowserDomTarget> targets,
        BrowserViewport? viewport,
        Rect windowBounds,
        string? process)
    {
        // Coordinate model:
        //   - Extension reports rect X/Y/W/H in CSS pixels relative to the viewport.
        //   - viewport.ScreenX/Y is the screen position of the viewport ORIGIN in CSS pixels
        //     (Chrome standardised on CSS pixels for Window.screen* in M89+).
        //   - Host overlay code expects DEVICE pixels. So we multiply the sum by DPR.
        double cssOriginX, cssOriginY, cssWidth, cssHeight;
        double dpr;
        if (viewport is not null && viewport.Width > 0 && viewport.Height > 0)
        {
            cssOriginX = viewport.ScreenX;
            cssOriginY = viewport.ScreenY;
            cssWidth = viewport.Width;
            cssHeight = viewport.Height;
            dpr = viewport.DevicePixelRatio <= 0 ? 1.0 : viewport.DevicePixelRatio;
        }
        else
        {
            // Fallback when the extension predates the viewport payload.
            const int TopChromePx = 104;
            cssOriginX = windowBounds.Left;
            cssOriginY = windowBounds.Top + TopChromePx;
            cssWidth = windowBounds.Width;
            cssHeight = Math.Max(0, windowBounds.Height - TopChromePx);
            dpr = 1.0;
        }

        var viewportLeft = (int)Math.Round(cssOriginX * dpr);
        var viewportTop = (int)Math.Round(cssOriginY * dpr);
        var viewportRight = (int)Math.Round((cssOriginX + cssWidth) * dpr);
        var viewportBottom = (int)Math.Round((cssOriginY + cssHeight) * dpr);

        var output = new List<UiTarget>(targets.Count);
        foreach (var t in targets)
        {
            if (!t.Visible || string.IsNullOrWhiteSpace(t.Label)) continue;
            if (t.Width <= 1 || t.Height <= 1) continue;
            if (t.X + t.Width < 0 || t.Y + t.Height < 0) continue;

            var screenLeft = (int)Math.Round((cssOriginX + t.X) * dpr);
            var screenTop = (int)Math.Round((cssOriginY + t.Y) * dpr);
            var screenRight = (int)Math.Round((cssOriginX + t.X + t.Width) * dpr);
            var screenBottom = (int)Math.Round((cssOriginY + t.Y + t.Height) * dpr);

            // Clip to viewport rect — drops elements fully below the fold / off-screen.
            if (screenLeft >= viewportRight || screenTop >= viewportBottom) continue;
            if (screenRight <= viewportLeft || screenBottom <= viewportTop) continue;

            output.Add(new UiTarget(
                Label: t.Label.Trim(),
                Role: NormalizeRole(t.Role),
                Bounds: new Rect(screenLeft, screenTop, screenRight, screenBottom),
                Confidence: t.Enabled ? 0.9 : 0.55,
                Source: TargetSource.BrowserDom,
                ActionHint: t.Role.Equals("link", StringComparison.OrdinalIgnoreCase) ? "navigate" : "click",
                Selector: t.Selector,
                Enabled: t.Enabled,
                Process: process));
        }
        return output;
    }

    private static string NormalizeRole(string role) =>
        role.ToLowerInvariant() switch
        {
            "" => "control",
            "input" => "textbox",
            _ => role.ToLowerInvariant()
        };
}
