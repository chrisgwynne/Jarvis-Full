using System.Diagnostics;
using System.Windows.Automation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Selection;

/// <summary>
/// Reads the currently selected text from the focused UI Automation element.
/// Strategy:
///   1. Get focused element.
///   2. If it exposes TextPattern → read GetSelection().
///   3. Else if it exposes ValuePattern / LegacyIAccessiblePattern with a value → use that.
///   4. Else if it exposes SelectionPattern with selectable item → use AutomationProperties.Name.
/// Never falls back to clipboard (per spec — don't hijack clipboard for selection reads).
///
/// All UIA calls have a hard 200ms internal budget; if a misbehaving app blocks longer we
/// abort to keep callers latency-bounded.
/// </summary>
public sealed class UIAutomationSelectedTextProvider : ISelectedTextProvider
{
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<UIAutomationSelectedTextProvider>? _logger;
    private readonly TimeSpan _budget;

    public UIAutomationSelectedTextProvider(
        IDiagnostics? diagnostics = null,
        ILogger<UIAutomationSelectedTextProvider>? logger = null,
        TimeSpan? budget = null)
    {
        _diagnostics = diagnostics;
        _logger = logger;
        _budget = budget ?? TimeSpan.FromMilliseconds(250);
    }

    public SelectedTextSnapshot TryReadSelection()
    {
        var sw = Stopwatch.StartNew();
        string? sourceApp = null;
        try
        {
            var task = Task.Run(() => ReadInternal());
            if (!task.Wait(_budget))
            {
                _diagnostics?.RecordMetric("selection.timeoutMs", sw.Elapsed.TotalMilliseconds);
                return SelectedTextSnapshot.Empty(sourceApp);
            }
            var snap = task.Result;
            _diagnostics?.RecordMetric("selection.readMs", sw.Elapsed.TotalMilliseconds);
            return snap;
        }
        catch (Exception ex)
        {
            _logger?.LogDebug(ex, "Selection read failed");
            _diagnostics?.Record(DiagnosticLevel.Debug, "selection", "read failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
            return SelectedTextSnapshot.Empty(sourceApp);
        }
    }

    private SelectedTextSnapshot ReadInternal()
    {
        var focused = AutomationElement.FocusedElement;
        if (focused is null) return SelectedTextSnapshot.Empty();

        var info = SafeInfo(focused);

        // 1. TextPattern is the canonical path (editors, text inputs, browsers exposing text).
        if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var tp) && tp is TextPattern textPattern)
        {
            try
            {
                var ranges = textPattern.GetSelection();
                if (ranges is { Length: > 0 })
                {
                    var sb = new System.Text.StringBuilder();
                    foreach (var r in ranges)
                    {
                        var t = r.GetText(-1);
                        if (!string.IsNullOrEmpty(t)) sb.Append(t);
                    }
                    if (sb.Length > 0)
                        return new SelectedTextSnapshot(DateTimeOffset.UtcNow, sb.ToString(), info.app, info.name, info.id, info.ctrl, true);
                }
            }
            catch { /* fall through to next strategy */ }
        }

        // 2. ValuePattern (e.g. single-line edits, combo boxes) — only meaningful if the entire
        //    field is "selected" (we can't know without TextPattern, but treat the value as the
        //    semantic "what the user is focused on").
        if (focused.TryGetCurrentPattern(ValuePattern.Pattern, out var vp) && vp is ValuePattern valuePattern)
        {
            var v = valuePattern.Current.Value;
            if (!string.IsNullOrEmpty(v))
                return new SelectedTextSnapshot(DateTimeOffset.UtcNow, v, info.app, info.name, info.id, info.ctrl, true);
        }

        // 3. SelectionPattern (lists, trees) — return the names of selected items.
        if (focused.TryGetCurrentPattern(SelectionPattern.Pattern, out var sp) && sp is SelectionPattern selectionPattern)
        {
            try
            {
                var items = selectionPattern.Current.GetSelection();
                if (items is { Length: > 0 })
                {
                    var names = items.Select(e => SafeInfo(e).name).Where(n => !string.IsNullOrEmpty(n));
                    var joined = string.Join("\n", names);
                    if (!string.IsNullOrEmpty(joined))
                        return new SelectedTextSnapshot(DateTimeOffset.UtcNow, joined, info.app, info.name, info.id, info.ctrl, true);
                }
            }
            catch { /* fall through */ }
        }

        return new SelectedTextSnapshot(DateTimeOffset.UtcNow, null, info.app, info.name, info.id, info.ctrl, true);
    }

    private static (string? app, string? name, string? id, string? ctrl) SafeInfo(AutomationElement el)
    {
        try
        {
            var c = el.Current;
            string? app = null;
            try
            {
                using var p = Process.GetProcessById(c.ProcessId);
                app = p.ProcessName;
            }
            catch { /* may have exited */ }
            return (app, c.Name, c.AutomationId, c.ControlType?.ProgrammaticName);
        }
        catch
        {
            return (null, null, null, null);
        }
    }
}
