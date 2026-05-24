using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;

namespace Jarvis.Core.Guidance;

public enum TargetSource
{
    BrowserDom,
    UiAutomation,
    Ocr,
    Heuristic
}

/// <summary>
/// A clickable / actionable thing Jarvis has discovered on screen. Discovery is
/// strictly read-only; converting a target into a real click goes through the
/// existing AutomationExecutor + approval policy.
/// </summary>
public sealed record UiTarget(
    string Label,
    string Role,
    Rect Bounds,
    double Confidence,
    TargetSource Source,
    string? ActionHint = null,
    SafetyTier SafetyTier = SafetyTier.Approve,
    /// <summary>Browser CSS selector when <see cref="Source"/> is BrowserDom; UIA
    /// AutomationId for UiAutomation; null otherwise.</summary>
    string? Selector = null,
    string? AutomationId = null,
    bool Enabled = true,
    /// <summary>Process the target belongs to. Used to skip targets from a non-foreground app.</summary>
    string? Process = null)
{
    public (double X, double Y) Center => (
        Bounds.Left + Bounds.Width / 2.0,
        Bounds.Top + Bounds.Height / 2.0);

    public bool IsValid =>
        !string.IsNullOrWhiteSpace(Label) &&
        Bounds.Width > 0 &&
        Bounds.Height > 0;
}

/// <summary>One backend that produces candidates. Implementations live in Jarvis.Perception
/// (UIA, browser-DOM, OCR). Each call is bounded — never blocks longer than a couple
/// hundred milliseconds — and never has side effects on the host machine.</summary>
public interface IUiTargetSource
{
    TargetSource Source { get; }
    Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext context, CancellationToken cancellationToken);
}

/// <summary>Input plumbing every source receives. Sources pull whatever they need
/// (foreground app, cursor position, OCR availability). Sources may return an empty
/// list cheaply when they have nothing to contribute.</summary>
public sealed record TargetDiscoveryContext(
    string? Query,
    string? ForegroundProcess,
    string? ForegroundWindowTitle,
    nint ForegroundWindowHandle,
    Rect ForegroundWindowBounds,
    int CursorX,
    int CursorY,
    bool BrowserConnected,
    bool AllowOcrFallback);
