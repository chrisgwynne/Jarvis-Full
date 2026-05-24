using System.Diagnostics;
using Jarvis.Core.Automation;
using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;
using Jarvis.Core.Perception;

namespace Jarvis.Perception.Guidance;

/// <summary>
/// Orchestrates target discovery, ranking, highlighting, and the "click it" follow-up.
///
/// Concurrency (P4.5):
///   - Single in-flight query. New AskAsync cancels the previous via a linked CTS.
///   - 200ms debounce: same query within the window returns the cached result.
///
/// OCR fallback policy unchanged from P4: fires only when (a) the browser isn't driving
/// and (b) UIA returned &lt; 3 candidates. Always on-demand; never continuous.
/// </summary>
public sealed class GuidanceService : IGuidanceService
{
    private static readonly TimeSpan DebounceWindow = TimeSpan.FromMilliseconds(200);

    private readonly IDesktopAwarenessService _awareness;
    private readonly IBrowserContext _browser;
    private readonly IHighlightRenderer _highlighter;
    private readonly IReadOnlyList<IUiTargetSource> _sources;
    private readonly IDiagnostics? _diagnostics;
    private readonly Func<(int X, int Y)> _cursorReader;
    private readonly object _gate = new();
    private UiTarget? _last;
    private GuidanceDiagnostics? _lastDiagnostics;
    private GuidanceResult? _lastResult;
    private CancellationTokenSource? _activeCts;
    private DateTimeOffset _lastCallAt;
    private string _lastQuery = "";

    public GuidanceService(
        IDesktopAwarenessService awareness,
        IBrowserContext browser,
        IHighlightRenderer highlighter,
        IEnumerable<IUiTargetSource> sources,
        Func<(int X, int Y)> cursorReader,
        IDiagnostics? diagnostics = null)
    {
        _awareness = awareness;
        _browser = browser;
        _highlighter = highlighter;
        _sources = sources.ToArray();
        _cursorReader = cursorReader;
        _diagnostics = diagnostics;
    }

    public UiTarget? LastHighlighted { get { lock (_gate) return _last; } }
    public GuidanceDiagnostics? LastDiagnostics { get { lock (_gate) return _lastDiagnostics; } }
    public void Clear() { lock (_gate) { _last = null; } }

    public async Task<GuidanceResult> AskAsync(string query, CancellationToken cancellationToken = default)
    {
        query ??= "";

        // Debounce
        lock (_gate)
        {
            var sinceLast = DateTimeOffset.UtcNow - _lastCallAt;
            if (sinceLast < DebounceWindow
                && string.Equals(_lastQuery, query, StringComparison.OrdinalIgnoreCase)
                && _lastResult is not null)
            {
                _diagnostics?.Record(DiagnosticLevel.Debug, "guidance", "suppressed (debounce)",
                    new Dictionary<string, object?> { ["query"] = query, ["ms"] = sinceLast.TotalMilliseconds });
                if (_lastDiagnostics is not null)
                    _lastDiagnostics = _lastDiagnostics with { Suppressed = true };
                return _lastResult;
            }
            _lastCallAt = DateTimeOffset.UtcNow;
            _lastQuery = query;
        }

        // Cancel any in-flight query, but DO NOT dispose its CTS — the older AskAsync
        // is still awaiting tasks that hold a token off the same source. The older
        // call's finally block disposes when it observes _activeCts no longer references it.
        CancellationTokenSource? previous;
        CancellationTokenSource currentCts;
        lock (_gate)
        {
            previous = _activeCts;
            currentCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _activeCts = currentCts;
        }
        try { previous?.Cancel(); } catch { /* already disposed elsewhere */ }

        var sw = Stopwatch.StartNew();
        var sourceLatency = new Dictionary<TargetSource, double>();
        var sourceCounts = new Dictionary<TargetSource, int>();
        try
        {
            var desktop = _awareness.Latest;
            var (cursorX, cursorY) = _cursorReader();
            var context = new TargetDiscoveryContext(
                Query: query,
                ForegroundProcess: desktop?.ForegroundProcessName,
                ForegroundWindowTitle: desktop?.ForegroundWindowTitle,
                ForegroundWindowHandle: desktop?.ForegroundWindowHandle ?? 0,
                ForegroundWindowBounds: desktop?.ForegroundWindowBounds ?? Rect.Empty,
                CursorX: cursorX,
                CursorY: cursorY,
                BrowserConnected: _browser.IsConnected,
                AllowOcrFallback: false);

            var primary = await DiscoverAcrossAsync(context, skipOcr: true,
                sourceLatency, sourceCounts, currentCts.Token).ConfigureAwait(false);

            IReadOnlyList<UiTarget> all = primary;
            if (NeedsOcrFallback(primary, context.BrowserConnected))
            {
                var ocr = await DiscoverAcrossAsync(context with { AllowOcrFallback = true },
                    skipOcr: false, sourceLatency, sourceCounts, currentCts.Token,
                    onlySource: TargetSource.Ocr).ConfigureAwait(false);
                all = primary.Concat(ocr).ToList();
            }

            var ranked = TargetRanker.Rank(query, all, cursorX, cursorY, context.ForegroundProcess);
            var best = ranked.Count > 0 ? ranked[0] : null;
            var lowConf = best is null || best.Score < 0.35;

            ClickIntent? suggested = null;
            string explanation;

            if (best is null)
            {
                explanation = all.Count == 0
                    ? "I couldn't see any candidate targets in the active window."
                    : "I found some candidates but none matched the query well enough.";
            }
            else if (lowConf)
            {
                explanation = $"This looks like it might be \"{best.Target.Label}\" ({best.Target.Role}), but I'm not sure. Try rephrasing.";
            }
            else
            {
                explanation = $"This looks like the {best.Target.Label} {best.Target.Role}. Source: {best.Target.Source}.";
                var (cx, cy) = best.Target.Center;
                suggested = new ClickIntent((int)Math.Round(cx), (int)Math.Round(cy));
                await _highlighter.ShowAsync(
                    best.Target.Bounds.Left,
                    best.Target.Bounds.Top,
                    best.Target.Bounds.Width,
                    best.Target.Bounds.Height,
                    label: $"Click here: {best.Target.Label}",
                    duration: TimeSpan.FromMilliseconds(1500),
                    currentCts.Token).ConfigureAwait(false);
                lock (_gate) _last = best.Target;
            }

            sw.Stop();
            var result = new GuidanceResult(query, best?.Target, ranked, explanation, suggested, lowConf);
            var diag = new GuidanceDiagnostics(
                Query: query,
                TotalMs: sw.Elapsed.TotalMilliseconds,
                SourceLatencyMs: sourceLatency,
                SourceCandidateCounts: sourceCounts,
                WinnerLabel: best?.Target.Label,
                WinnerSource: best?.Target.Source,
                WinnerScore: best?.Score ?? 0,
                LowConfidence: lowConf,
                Cancelled: false,
                Suppressed: false);
            lock (_gate)
            {
                _lastResult = result;
                _lastDiagnostics = diag;
            }
            _diagnostics?.Record(DiagnosticLevel.Info, "guidance", "ask",
                new Dictionary<string, object?>
                {
                    ["query"] = query,
                    ["totalMs"] = sw.Elapsed.TotalMilliseconds,
                    ["candidates"] = all.Count,
                    ["winnerLabel"] = best?.Target.Label,
                    ["winnerSource"] = best?.Target.Source.ToString(),
                    ["winnerScore"] = best?.Score,
                    ["lowConfidence"] = lowConf
                });
            return result;
        }
        catch (OperationCanceledException)
        {
            sw.Stop();
            var diag = new GuidanceDiagnostics(
                Query: query, TotalMs: sw.Elapsed.TotalMilliseconds,
                SourceLatencyMs: sourceLatency, SourceCandidateCounts: sourceCounts,
                WinnerLabel: null, WinnerSource: null, WinnerScore: 0,
                LowConfidence: true, Cancelled: true, Suppressed: false);
            lock (_gate) _lastDiagnostics = diag;
            _diagnostics?.Record(DiagnosticLevel.Debug, "guidance", "cancelled",
                new Dictionary<string, object?> { ["query"] = query });
            throw;
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_activeCts, currentCts))
                {
                    _activeCts.Dispose();
                    _activeCts = null;
                }
            }
        }
    }

    private async Task<IReadOnlyList<UiTarget>> DiscoverAcrossAsync(
        TargetDiscoveryContext context, bool skipOcr,
        Dictionary<TargetSource, double> latency,
        Dictionary<TargetSource, int> counts,
        CancellationToken cancellationToken,
        TargetSource? onlySource = null)
    {
        var tasks = new List<Task<(TargetSource Source, IReadOnlyList<UiTarget> Targets, double Ms)>>(_sources.Count);
        foreach (var src in _sources)
        {
            if (onlySource is not null && src.Source != onlySource) continue;
            if (skipOcr && src.Source == TargetSource.Ocr) continue;
            tasks.Add(TimedDiscover(src, context, cancellationToken));
        }
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        var output = new List<UiTarget>();
        foreach (var (source, targets, ms) in results)
        {
            latency[source] = latency.TryGetValue(source, out var prev) ? prev + ms : ms;
            counts[source] = counts.TryGetValue(source, out var prevCount) ? prevCount + targets.Count : targets.Count;
            output.AddRange(targets);
        }
        return output;
    }

    private static async Task<(TargetSource, IReadOnlyList<UiTarget>, double)> TimedDiscover(
        IUiTargetSource src, TargetDiscoveryContext ctx, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        IReadOnlyList<UiTarget> targets;
        try { targets = await src.DiscoverAsync(ctx, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch { targets = Array.Empty<UiTarget>(); }
        sw.Stop();
        return (src.Source, targets, sw.Elapsed.TotalMilliseconds);
    }

    private static bool NeedsOcrFallback(IReadOnlyList<UiTarget> primary, bool browserConnected)
    {
        if (browserConnected && primary.Any(t => t.Source == TargetSource.BrowserDom)) return false;
        var uia = primary.Count(t => t.Source == TargetSource.UiAutomation);
        return uia < 3;
    }
}
