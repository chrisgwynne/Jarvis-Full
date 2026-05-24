using System.Text.Json;
using Jarvis.Core.Automation;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Sidecar;

/// <summary>
/// Receives <c>execute.intent</c> frames from the Mac brain. The intent JSON is parsed
/// and handed to the existing <see cref="IAutomationExecutor"/> — so every Mac-driven
/// click / type / shortcut / file-open still passes through:
///   - <c>DefaultApprovalPolicy</c> (block-list, tier classification)
///   - <c>TokenBucketRateLimiter</c>
///   - <c>Win32ElevationProbe</c>
///   - <c>WpfApprovalGate</c> modal for Approve-tier intents
///   - <c>JsonlAuditLog</c>
///
/// The Mac never bypasses any of these. An ack frame (with the <c>AutomationOutcome</c>)
/// goes back via the bridge once the local pipeline finishes.
/// </summary>
public sealed class RemoteExecutionBridge : IRemoteExecutionBridge
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IMacBridgeCoordinator _bridge;
    private readonly IAutomationExecutor _executor;
    private readonly IDiagnostics? _diagnostics;
    private int _accepted, _rejected, _failed;
    private bool _attached;

    public RemoteExecutionBridge(IMacBridgeCoordinator bridge, IAutomationExecutor executor,
        IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _executor = executor;
        _diagnostics = diagnostics;
    }

    public int Accepted => _accepted;
    public int Rejected => _rejected;
    public int Failed => _failed;

    public void Attach()
    {
        if (_attached) return;
        _attached = true;
        _bridge.FrameReceived += OnFrame;
    }

    public void Dispose()
    {
        if (_attached) _bridge.FrameReceived -= OnFrame;
        _attached = false;
    }

    private async void OnFrame(object? sender, SidecarFrame frame)
    {
        if (frame.Type != SidecarFrameTypes.ExecuteIntent) return;
        var commandId = frame.CommandId ?? Guid.NewGuid().ToString("N");

        AutomationIntent? intent = null;
        try
        {
            intent = ParseIntent(frame.IntentKind, frame.IntentJson);
        }
        catch (Exception ex)
        {
            Interlocked.Increment(ref _rejected);
            await Ack(commandId, AutomationOutcome.Failed, $"parse error: {ex.Message}");
            return;
        }
        if (intent is null)
        {
            Interlocked.Increment(ref _rejected);
            await Ack(commandId, AutomationOutcome.Failed, $"unsupported intent kind '{frame.IntentKind}'");
            return;
        }

        Interlocked.Increment(ref _accepted);
        AutomationResult result;
        try { result = await _executor.ExecuteAsync(intent).ConfigureAwait(false); }
        catch (Exception ex)
        {
            Interlocked.Increment(ref _failed);
            await Ack(commandId, AutomationOutcome.Failed, ex.Message);
            return;
        }
        if (!result.Ok) Interlocked.Increment(ref _failed);
        await Ack(commandId, result.Outcome, result.Message);
        _diagnostics?.Record(result.Ok ? DiagnosticLevel.Info : DiagnosticLevel.Warn,
            "sidecar.execute", $"{intent.Kind} {result.Outcome}",
            new Dictionary<string, object?> { ["msg"] = result.Message, ["commandId"] = commandId });
    }

    private Task<bool> Ack(string commandId, AutomationOutcome outcome, string? message) =>
        _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.ExecuteAck,
            CommandId = commandId,
            Outcome = outcome.ToString(),
            Message = message,
            At = DateTimeOffset.UtcNow
        });

    /// <summary>
    /// Parse a Mac-supplied intent. We accept a small whitelist of kinds and rely on the
    /// receiving executor to enforce policy/safety. Anything we don't recognise here
    /// gets rejected at the bridge layer (a strictly tighter check than the policy alone).
    /// </summary>
    internal static AutomationIntent? ParseIntent(string? kind, string? json)
    {
        if (string.IsNullOrEmpty(kind) || string.IsNullOrEmpty(json)) return null;
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        string? Str(string n) => root.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        int Int(string n, int dflt = 0) => root.TryGetProperty(n, out var v) && v.TryGetInt32(out var i) ? i : dflt;
        bool Bool(string n, bool dflt = false) => root.TryGetProperty(n, out var v) && v.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => dflt };

        return kind switch
        {
            "window.focus" => new FocusWindowIntent(Str("process") ?? "", Str("titleSubstring")),
            "window.switchApp" => new SwitchAppIntent(Str("process") ?? ""),
            "keyboard.shortcut" => new SendShortcutIntent(Str("accelerator") ?? ""),
            "keyboard.type" => new TypeTextIntent(Str("text") ?? ""),
            "keyboard.paste" => new PasteTextIntent(Str("text") ?? ""),
            "keyboard.key" => new PressKeyIntent(Str("key") ?? ""),
            "mouse.move" => new MoveCursorIntent(Int("x"), Int("y")),
            "mouse.click" => new ClickIntent(Int("x"), Int("y"),
                Enum.TryParse<MouseButtonKind>(Str("button"), true, out var btn) ? btn : MouseButtonKind.Left,
                Math.Max(1, Int("count", 1))),
            "mouse.scroll" => new ScrollIntent(Int("dx"), Int("dy")),
            "ui.highlight" => new HighlightTargetIntent(Int("x"), Int("y"), Int("width"), Int("height"), Str("label")),
            "browser.navigate" => new BrowserNavigateIntent(Str("url") ?? ""),
            "browser.reload" => new BrowserReloadIntent(),
            "browser.back" => new BrowserHistoryIntent(BrowserHistoryDirection.Back),
            "browser.forward" => new BrowserHistoryIntent(BrowserHistoryDirection.Forward),
            "browser.focusInput" => new BrowserFocusInputIntent(Str("selector") ?? ""),
            "browser.extractSelection" => new BrowserExtractSelectionIntent(),
            "browser.scroll" => new BrowserScrollIntent(Int("dy")),
            "browser.click" => new BrowserClickSelectorIntent(Str("selector") ?? ""),
            "app.open" => new OpenAppIntent(Str("executable") ?? "", Str("arguments")),
            "file.open" => new OpenFileIntent(Str("path") ?? ""),
            "file.reveal" => new RevealFileIntent(Str("path") ?? ""),
            "file.createDraft" => new CreateDraftFileIntent(Str("path") ?? "", Str("content") ?? "", Bool("overwrite")),
            _ => null
        };
    }
}
