using Jarvis.Core.Context;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;
using Jarvis.Core.Sidecar;
using Jarvis.Core.Snapshot;
using Jarvis.Perception.Conversation;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Pushes a compact desktop snapshot to the Mac on every meaningful change. Uses the
/// existing <see cref="IContextBudgeter"/> so secrets are redacted and long fields
/// truncated before they cross the bridge. Drops duplicates by snapshot hash.
/// </summary>
public sealed class SidecarContextPublisher : ISidecarContextPublisher
{
    private readonly PerceptionService _perception;
    private readonly IConversationContextBuilder _builder;
    private readonly IContextBudgeter _budgeter;
    private readonly IMacBridgeCoordinator _bridge;
    private readonly Func<SidecarSettings> _settings;
    private readonly Func<AwarenessSettings>? _awarenessSettings;
    private readonly IWindowsContextEngine? _contextEngine;
    private readonly object _gate = new();
    private string? _lastHash;
    private int _published;
    private int _deduped;
    private bool _attached;

    public SidecarContextPublisher(
        PerceptionService perception,
        IConversationContextBuilder builder,
        IContextBudgeter budgeter,
        IMacBridgeCoordinator bridge,
        Func<SidecarSettings> settings,
        IWindowsContextEngine? contextEngine = null,
        Func<AwarenessSettings>? awarenessSettings = null)
    {
        _perception = perception;
        _builder = builder;
        _budgeter = budgeter;
        _bridge = bridge;
        _settings = settings;
        _contextEngine = contextEngine;
        _awarenessSettings = awarenessSettings;
    }

    public int Published { get { lock (_gate) return _published; } }
    public int Deduplicated { get { lock (_gate) return _deduped; } }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_attached) return Task.CompletedTask;
        _perception.Changed += OnPerceptionChanged;
        _attached = true;
        // Initial push
        _ = PublishCurrentAsync();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (_attached) _perception.Changed -= OnPerceptionChanged;
        _attached = false;
        return Task.CompletedTask;
    }

    private void OnPerceptionChanged(object? sender, SemanticSnapshot snap) => _ = PublishCurrentAsync();

    private async Task PublishCurrentAsync()
    {
        if (_settings().PrivacyMode) return;
        var ctx = _builder.Build();
        var (compact, _) = _budgeter.Budget(ctx);

        lock (_gate)
        {
            if (_lastHash == compact.SnapshotHash) { _deduped++; return; }
            _lastHash = compact.SnapshotHash;
            _published++;
        }

        var payload = new ContextPayload
        {
            ForegroundApp = compact.ForegroundApp,
            ForegroundWindowTitle = compact.ForegroundWindowTitle,
            Workflow = compact.Workflow.ToString(),
            SelectedText = compact.SelectedText,
            Clipboard = compact.ClipboardSummary,
            BrowserUrl = compact.Browser?.Url,
            BrowserTitle = compact.Browser?.Title,
            IdeEditor = compact.Ide?.Editor,
            IdeFile = compact.Ide?.ActiveFile,
            IdeRepo = compact.Ide?.RepoRoot,
            IdeBranch = compact.Ide?.Branch,
            RecentOcr = compact.RecentOcrSummary,
            LastHighlighted = compact.LastHighlighted?.Label
        };

        // Enrich with context-engine fields (focus, presence, timeline).
        // Skip enrichment when foreground-app tracking is disabled (privacy).
        var trackingEnabled = _awarenessSettings?.Invoke().TrackForegroundApp ?? true;
        if (trackingEnabled)
        {
            var engineCtx = _contextEngine?.Current;
            if (engineCtx is not null)
            {
                payload.FocusMinutes = engineCtx.Focus.FocusDuration.TotalMinutes;
                payload.PresenceMode = engineCtx.PresenceMode.ToString();
                payload.ProductivityScore = engineCtx.Focus.ProductivityScore;
                payload.AppSwitchesLast10Min = engineCtx.Focus.AppSwitchesLast10Min;
                payload.RecentApps = engineCtx.RecentProcessNames.Length > 0 ? engineCtx.RecentProcessNames : null;
                payload.TimelineSummary = engineCtx.Timeline.ToCompactSummary().NullIfEmpty();
            }
        }

        await _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.Context,
            SnapshotHash = compact.SnapshotHash,
            Context = payload,
            At = DateTimeOffset.UtcNow
        }).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);
}

file static class StringExtensions
{
    public static string? NullIfEmpty(this string? s) => string.IsNullOrEmpty(s) ? null : s;
}
