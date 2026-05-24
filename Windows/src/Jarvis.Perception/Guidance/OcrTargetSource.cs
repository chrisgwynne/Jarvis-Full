using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Guidance;

/// <summary>
/// OCR fallback for apps with a weak UI Automation tree. Only fires when allowed by
/// the orchestrator (no continuous OCR). Improvements over P4:
///   - groups OCR lines that look like part of one button label
///   - drops paragraph-shaped regions (long line, &gt; 40 chars) so we don't highlight
///     prose blocks
///   - clamps the per-target rect so highlights stay button-sized
///   - confidence stays capped at 0.4 so any UIA/DOM equivalent wins
/// </summary>
public sealed class OcrTargetSource : IUiTargetSource
{
    private readonly Func<Rect, Task<byte[]?>> _grabPng;
    private readonly IOcrService _ocr;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<OcrTargetSource>? _logger;

    public OcrTargetSource(
        Func<Rect, Task<byte[]?>> grabPng,
        IOcrService ocr,
        IDiagnostics? diagnostics = null,
        ILogger<OcrTargetSource>? logger = null)
    {
        _grabPng = grabPng;
        _ocr = ocr;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public TargetSource Source => TargetSource.Ocr;

    public async Task<IReadOnlyList<UiTarget>> DiscoverAsync(TargetDiscoveryContext context, CancellationToken cancellationToken)
    {
        if (!context.AllowOcrFallback || !_ocr.IsAvailable) return Array.Empty<UiTarget>();
        var bounds = context.ForegroundWindowBounds;
        if (bounds.IsEmpty || bounds.Width < 32 || bounds.Height < 32) return Array.Empty<UiTarget>();

        byte[]? png;
        try { png = await _grabPng(bounds).ConfigureAwait(false); }
        catch (Exception ex)
        {
            _logger?.LogDebug(ex, "OCR fallback grab failed");
            return Array.Empty<UiTarget>();
        }
        if (png is null || png.Length == 0) return Array.Empty<UiTarget>();

        var result = await _ocr.RecognizeAsync(png, cancellationToken).ConfigureAwait(false);
        _diagnostics?.RecordMetric("guidance.ocr.lines", result.Lines.Count);

        if (result.Lines.Count == 0) return Array.Empty<UiTarget>();
        return GroupLinesIntoTargets(result.Lines, bounds, context.ForegroundProcess);
    }

    /// <summary>
    /// Group OCR lines into candidate targets. Adjacent same-row lines that are close
    /// horizontally get merged (handles multi-word button labels split across OCR rows).
    /// Paragraph-shaped lines (&gt;40 chars) are dropped.
    /// </summary>
    internal static IReadOnlyList<UiTarget> GroupLinesIntoTargets(
        IReadOnlyList<OcrLine> lines, Rect windowBounds, string? process)
    {
        var boxes = new List<(string Text, Rect Bounds)>(lines.Count);
        foreach (var line in lines)
        {
            var label = line.Text?.Trim();
            if (string.IsNullOrWhiteSpace(label)) continue;
            if (line.Words.Count == 0) continue;
            if (label.Length > 40) continue;
            var minX = line.Words.Min(w => w.Bounds.X);
            var minY = line.Words.Min(w => w.Bounds.Y);
            var maxX = line.Words.Max(w => w.Bounds.X + w.Bounds.Width);
            var maxY = line.Words.Max(w => w.Bounds.Y + w.Bounds.Height);
            var screen = new Rect(
                Left: windowBounds.Left + (int)minX,
                Top: windowBounds.Top + (int)minY,
                Right: windowBounds.Left + (int)maxX,
                Bottom: windowBounds.Top + (int)maxY);
            if (screen.Width < 8 || screen.Height < 8) continue;
            if (screen.Width > windowBounds.Width * 0.6 && screen.Height < 20) continue;
            boxes.Add((label, screen));
        }

        if (boxes.Count == 0) return Array.Empty<UiTarget>();

        var used = new bool[boxes.Count];
        var groups = new List<(string Text, Rect Bounds)>();
        for (var i = 0; i < boxes.Count; i++)
        {
            if (used[i]) continue;
            used[i] = true;
            var current = boxes[i];
            for (var j = i + 1; j < boxes.Count; j++)
            {
                if (used[j]) continue;
                var b = boxes[j];
                var heightOverlap = !(current.Bounds.Bottom < b.Bounds.Top || b.Bounds.Bottom < current.Bounds.Top);
                if (!heightOverlap) continue;
                var gap = Math.Min(
                    Math.Abs(b.Bounds.Left - current.Bounds.Right),
                    Math.Abs(current.Bounds.Left - b.Bounds.Right));
                if (gap > current.Bounds.Height * 1.2) continue;
                used[j] = true;
                var merged = new Rect(
                    Math.Min(current.Bounds.Left, b.Bounds.Left),
                    Math.Min(current.Bounds.Top, b.Bounds.Top),
                    Math.Max(current.Bounds.Right, b.Bounds.Right),
                    Math.Max(current.Bounds.Bottom, b.Bounds.Bottom));
                current = ((current.Bounds.Left <= b.Bounds.Left)
                    ? current.Text + " " + b.Text
                    : b.Text + " " + current.Text, merged);
            }
            if (current.Bounds.Width > 480 || current.Bounds.Height > 80) continue;
            groups.Add(current);
        }

        var output = new List<UiTarget>(groups.Count);
        foreach (var g in groups)
        {
            output.Add(new UiTarget(
                Label: g.Text,
                Role: GuessRole(g.Text),
                Bounds: g.Bounds,
                Confidence: 0.35,
                Source: TargetSource.Ocr,
                ActionHint: "click",
                Enabled: true,
                Process: process));
        }
        return output;
    }

    internal static string GuessRole(string label)
    {
        var trimmed = label.Trim();
        if (trimmed.Length <= 24 && !trimmed.Contains(' ')) return "button";
        if (trimmed.Contains(' ') && trimmed.Length <= 28) return "button";
        return "text";
    }
}
