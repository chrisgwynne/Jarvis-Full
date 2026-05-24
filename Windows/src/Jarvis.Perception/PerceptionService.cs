using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception;

/// <summary>
/// Coordinator: holds the latest observations and produces semantic snapshots on demand.
/// Reads are cheap and side-effect-free; the only writes happen when new observations land
/// (clipboard listener, capture, OCR completion).
///
/// Concurrency: all state behind a single lock. Snapshot building is pure so it can run
/// outside the lock once inputs have been copied.
/// </summary>
public sealed class PerceptionService
{
    private readonly IDesktopAwarenessService _awareness;
    private readonly ISelectedTextProvider _selection;
    private readonly IClipboardMonitor _clipboard;
    private readonly IBrowserContext _browser;
    private readonly IIdeContextProvider _ide;
    private readonly ISemanticSnapshotBuilder _builder;
    private readonly IDiagnostics? _diagnostics;
    private readonly object _gate = new();

    private OcrResult? _recentOcr;
    private SemanticSnapshot _cachedSnapshot = SemanticSnapshot.Empty;
    private string _cachedHash = "0";

    /// <summary>Raised when a fresh BuildCurrent produces a different hash than last time.
    /// Consumers (Context Inspector, future LLM context streamer) subscribe here instead of polling.</summary>
    public event EventHandler<SemanticSnapshot>? Changed;

    public PerceptionService(
        IDesktopAwarenessService awareness,
        ISelectedTextProvider selection,
        IClipboardMonitor clipboard,
        IBrowserContext browser,
        IIdeContextProvider ide,
        ISemanticSnapshotBuilder builder,
        IDiagnostics? diagnostics = null)
    {
        _awareness = awareness;
        _selection = selection;
        _clipboard = clipboard;
        _browser = browser;
        _ide = ide;
        _builder = builder;
        _diagnostics = diagnostics;

        // Event-driven refreshes: any meaningful change re-builds + raises Changed.
        _awareness.SnapshotChanged += (_, _) => SafeRebuild();
        _clipboard.Changed += (_, _) => SafeRebuild();
        _browser.Updated += (_, _) => SafeRebuild();
    }

    private void SafeRebuild()
    {
        try { _ = BuildCurrent(); }
        catch (Exception ex)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "snapshot", "rebuild failed",
                new Dictionary<string, object?> { ["error"] = ex.Message });
        }
    }

    public OcrResult? RecentOcr { get { lock (_gate) return _recentOcr; } }

    public void SetRecentOcr(OcrResult? result)
    {
        lock (_gate) _recentOcr = result;
    }

    public SemanticSnapshot BuildCurrent()
    {
        OcrResult? ocr;
        lock (_gate) ocr = _recentOcr;

        var inputs = new SemanticSnapshotInputs(
            Desktop: _awareness.Latest,
            Selection: _selection.TryReadSelection(),
            Clipboard: _clipboard.Latest,
            Browser: _browser.Current,
            Ide: _ide.TryReadContext(),
            RecentOcr: ocr);

        var snap = _builder.Build(inputs);

        bool changed;
        lock (_gate)
        {
            changed = snap.Hash != _cachedHash;
            if (changed)
            {
                _cachedHash = snap.Hash;
                _cachedSnapshot = snap;
            }
        }

        if (changed)
        {
            _diagnostics?.Record(DiagnosticLevel.Debug, "snapshot", "rebuilt",
                new Dictionary<string, object?>
                {
                    ["workflow"] = snap.Workflow.ToString(),
                    ["app"] = snap.ForegroundApp,
                    ["hash"] = snap.Hash
                });
            Changed?.Invoke(this, snap);
        }
        return changed ? snap : _cachedSnapshot;
    }

    public SemanticSnapshot LastBuilt
    {
        get { lock (_gate) return _cachedSnapshot; }
    }
}
