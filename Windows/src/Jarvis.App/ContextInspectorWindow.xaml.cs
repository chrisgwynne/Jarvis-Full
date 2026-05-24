using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Button = System.Windows.Controls.Button;
using Jarvis.Core.Automation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Guidance;
using Jarvis.Core.Snapshot;
using Jarvis.Perception;

namespace Jarvis.App;

public partial class ContextInspectorWindow : Window
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    private readonly PerceptionService _perception;
    private readonly Func<OcrSummary?> _ocrProvider;
    private readonly IDiagnostics _diagnostics;
    private readonly IAuditLog _audit;
    private readonly IGuidanceService _guidance;
    private readonly IHighlightRenderer _highlighter;
    private readonly DispatcherTimer _fallbackTimer;
    private SemanticSnapshot _last = SemanticSnapshot.Empty;
    private int _updates;

    public sealed record OcrSummary(string Text, double DurationMs, string Language);

    public ContextInspectorWindow(
        PerceptionService perception,
        Func<OcrSummary?> ocrProvider,
        IDiagnostics diagnostics,
        IAuditLog audit,
        IGuidanceService guidance,
        IHighlightRenderer highlighter)
    {
        _perception = perception;
        _ocrProvider = ocrProvider;
        _diagnostics = diagnostics;
        _audit = audit;
        _guidance = guidance;
        _highlighter = highlighter;
        InitializeComponent();
        _fallbackTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(2) };
        _fallbackTimer.Tick += (_, _) => RenderOnce();
        _perception.Changed += OnPerceptionChanged;
        Loaded += (_, _) => { _fallbackTimer.Start(); RenderOnce(); };
        Closed += (_, _) =>
        {
            _fallbackTimer.Stop();
            _perception.Changed -= OnPerceptionChanged;
        };
    }

    private void OnPerceptionChanged(object? sender, SemanticSnapshot snap)
    {
        Dispatcher.BeginInvoke(() => { if (StreamMode.IsChecked == true) RenderOnce(); });
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => RenderOnce();

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        try { System.Windows.Clipboard.SetText(JsonSerializer.Serialize(_last, JsonOpts)); } catch { }
    }

    private async void OnDiscoverTargets(object sender, RoutedEventArgs e)
    {
        var q = DiscoverQueryBox.Text.Trim();
        if (string.IsNullOrEmpty(q)) q = "any";
        try
        {
            var result = await _guidance.AskAsync(q);
            TargetsList.ItemsSource = result.Candidates.Take(20).ToList();
            var d = _guidance.LastDiagnostics;
            GuidanceSummary.Text = d is null
                ? "—"
                : $"\"{d.Query}\" · {d.TotalMs:F0}ms · {string.Join(", ", d.SourceCandidateCounts.Select(kv => $"{kv.Key}:{kv.Value}"))}"
                  + (d.LowConfidence ? " · low confidence" : "")
                  + (d.WinnerLabel is null ? "" : $" · winner: {d.WinnerLabel} ({d.WinnerScore:F2})");
        }
        catch (Exception ex)
        {
            GuidanceSummary.Text = $"Failed: {ex.Message}";
        }
    }

    private async void OnHighlightTarget(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not UiTarget t) return;
        await _highlighter.ShowAsync(
            t.Bounds.Left, t.Bounds.Top, t.Bounds.Width, t.Bounds.Height,
            label: $"Target: {t.Label}", duration: TimeSpan.FromMilliseconds(1500));
    }

    private void OnCopyTarget(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not UiTarget t) return;
        try { System.Windows.Clipboard.SetText(JsonSerializer.Serialize(t, JsonOpts)); } catch { }
    }

    private void RenderOnce()
    {
        var snap = _perception.BuildCurrent();
        _last = snap;
        _updates++;
        UpdateCount.Text = $"{_updates} updates";

        WorkflowText.Text = snap.Workflow.ToString();
        ForegroundText.Text = $"{snap.ForegroundApp ?? "—"} · {snap.ForegroundWindowTitle ?? "—"}";

        IdeText.Text = snap.Ide is { HasContent: true } ide
            ? $"{ide.Editor ?? "—"}\nfile: {ide.ActiveFile ?? "—"}\nproject: {ide.ProjectRoot ?? "—"}\nrepo: {ide.RepoRoot ?? "—"} @ {ide.Branch ?? "—"}"
            : "—";

        SelectionText.Text = string.IsNullOrEmpty(snap.SelectedText)
            ? "—"
            : $"[{snap.SelectedTextType}] {Preview(snap.SelectedText, 800)}";
        ClipboardText.Text = string.IsNullOrEmpty(snap.ClipboardSummary)
            ? "—"
            : $"[{snap.ClipboardType}] {Preview(snap.ClipboardSummary, 300)}";

        BrowserText.Text = snap.Browser is { Url: not null } b
            ? $"{b.Browser ?? "?"} · {b.Url}\ntitle: {b.Title ?? "—"}\nfocused input: {b.IsTextInputFocused}\nselection: {Preview(b.SelectedText ?? "", 200)}"
            : "(extension not connected)";

        var ocr = _ocrProvider();
        OcrText.Text = ocr is null ? "—" : $"[{ocr.Language} · {ocr.DurationMs:F0}ms]\n{Preview(ocr.Text, 1200)}";

        var metrics = _diagnostics.Metrics;
        MetricsText.Text = string.Join('\n', metrics.OrderBy(kv => kv.Key).Select(kv => $"{kv.Key}={kv.Value:F2}"));
        HashText.Text = snap.Hash;
        RecentActionsList.ItemsSource = _audit.Recent(10).Reverse().ToList();
    }

    private static string Preview(string s, int max) =>
        s.Length <= max ? s : s[..max] + " …";
}
