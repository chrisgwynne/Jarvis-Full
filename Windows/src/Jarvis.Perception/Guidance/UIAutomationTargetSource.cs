using System.Windows.Automation;
using JarvisRect = Jarvis.Core.Awareness.Rect;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Guidance;

/// <summary>
/// Walks the UI Automation subtree rooted at the foreground window and produces one
/// candidate per interactive control. Breadth-first so we don't fall down a deeply
/// nested Electron node and exhaust the cap before getting to anything useful.
///
/// Filters (applied as the walk proceeds, not in a second pass):
///   - off-screen / zero-size — culled before children are queued
///   - disabled — kept with reduced confidence so the user sees why nothing happened
///   - container-sized (>= 80% of the window) — dropped from results, children still walked
///   - missing name — dropped
///
/// Wall-clock budget: hard 250 ms cap (cancellable). Element-visit cap: configurable
/// (default 2,500). When the cap fires we record a diagnostic so it's visible in
/// the inspector.
/// </summary>
public sealed class UIAutomationTargetSource : IUiTargetSource
{
    private static readonly HashSet<string> InteractiveControlTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "Button", "MenuItem", "TabItem", "CheckBox", "RadioButton",
        "Edit", "Hyperlink", "ListItem", "TreeItem", "ComboBox", "SplitButton"
    };

    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<UIAutomationTargetSource>? _logger;
    private readonly TimeSpan _budget;
    private readonly int _maxElements;

    public UIAutomationTargetSource(
        IDiagnostics? diagnostics = null,
        ILogger<UIAutomationTargetSource>? logger = null,
        TimeSpan? budget = null,
        int maxElements = 2_500)
    {
        _diagnostics = diagnostics;
        _logger = logger;
        _budget = budget ?? TimeSpan.FromMilliseconds(250);
        _maxElements = Math.Max(100, maxElements);
    }

    public TargetSource Source => TargetSource.UiAutomation;

    public async Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext context, CancellationToken cancellationToken)
    {
        if (context.ForegroundWindowHandle == 0) return Array.Empty<UiTarget>();
        var task = Task.Run(() => Walk(context, cancellationToken), cancellationToken);
        var winner = await Task.WhenAny(task, Task.Delay(_budget, cancellationToken)).ConfigureAwait(false);
        if (winner != task)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "guidance.uia", "timed out");
            return Array.Empty<UiTarget>();
        }
        try { return await task.ConfigureAwait(false); }
        catch (Exception ex)
        {
            _logger?.LogDebug(ex, "UIA walk failed");
            return Array.Empty<UiTarget>();
        }
    }

    private IReadOnlyList<UiTarget> Walk(TargetDiscoveryContext context, CancellationToken cancellationToken)
    {
        AutomationElement? root;
        try { root = AutomationElement.FromHandle(context.ForegroundWindowHandle); }
        catch { return Array.Empty<UiTarget>(); }
        if (root is null) return Array.Empty<UiTarget>();

        var windowBounds = context.ForegroundWindowBounds;
        var windowArea = (double)Math.Max(1, windowBounds.Width * windowBounds.Height);

        var results = new List<UiTarget>(64);
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        var visited = 0;
        var capHit = false;

        while (queue.Count > 0)
        {
            if (cancellationToken.IsCancellationRequested) break;
            if (visited >= _maxElements) { capHit = true; break; }
            visited++;
            var element = queue.Dequeue();

            AutomationElement.AutomationElementInformation info;
            try { info = element.Current; }
            catch { continue; }

            // Off-screen → drop subtree entirely. Saves significant time on long lists.
            if (info.IsOffscreen) continue;

            var rect = info.BoundingRectangle;
            // If the rect intersects nothing on screen, the subtree is invisible too.
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            if (!IntersectsWindow(rect, windowBounds)) continue;

            // Candidate?
            var typeName = info.ControlType?.ProgrammaticName?.Split('.').LastOrDefault() ?? "";
            if (InteractiveControlTypes.Contains(typeName))
            {
                var bounds = new JarvisRect((int)rect.Left, (int)rect.Top, (int)rect.Right, (int)rect.Bottom);
                var area = (double)bounds.Width * bounds.Height;
                if (area <= windowArea * 0.8)
                {
                    var label = SafeName(element);
                    if (!string.IsNullOrWhiteSpace(label))
                    {
                        results.Add(new UiTarget(
                            Label: label,
                            Role: info.ControlType?.LocalizedControlType ?? "control",
                            Bounds: bounds,
                            Confidence: info.IsEnabled ? 0.8 : 0.5,
                            Source: TargetSource.UiAutomation,
                            ActionHint: "click",
                            AutomationId: string.IsNullOrEmpty(info.AutomationId) ? null : info.AutomationId,
                            Enabled: info.IsEnabled,
                            Process: context.ForegroundProcess));
                    }
                }
            }

            // Enqueue children.
            try
            {
                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                while (child is not null)
                {
                    queue.Enqueue(child);
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
            }
            catch { /* element vanished */ }
        }

        _diagnostics?.RecordMetric("guidance.uia.visited", visited);
        _diagnostics?.RecordMetric("guidance.uia.kept", results.Count);
        if (capHit)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "guidance.uia", "element cap reached",
                new Dictionary<string, object?> { ["max"] = _maxElements, ["kept"] = results.Count });
        }
        return results;
    }

    private static bool IntersectsWindow(System.Windows.Rect uiaRect, JarvisRect window)
    {
        if (window.IsEmpty) return true; // unknown window bounds → don't pre-filter
        return uiaRect.Right > window.Left
            && uiaRect.Left < window.Right
            && uiaRect.Bottom > window.Top
            && uiaRect.Top < window.Bottom;
    }

    private static string SafeName(AutomationElement el)
    {
        try
        {
            var name = el.Current.Name;
            return string.IsNullOrWhiteSpace(name) ? string.Empty : name.Trim();
        }
        catch { return string.Empty; }
    }
}
