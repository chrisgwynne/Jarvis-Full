namespace Jarvis.Core.Automation;

public interface IAutomationExecutor
{
    /// <summary>Classify + plan + (optionally) get approval + execute + audit.</summary>
    Task<AutomationResult> ExecuteAsync(AutomationIntent intent, CancellationToken cancellationToken = default);

    /// <summary>Run only the planner, without classification side effects beyond returning the plan.</summary>
    AutomationPlan DryRun(AutomationIntent intent);
}

/// <summary>
/// Low-level dispatch surfaces — split by category so each can be mocked independently
/// in tests. Implementations live in Jarvis.Automation.
/// </summary>
public interface IWindowAutomationSurface
{
    Task<string?> FocusAsync(string process, string? titleSubstring, CancellationToken cancellationToken);
    Task<string?> MoveAsync(IntPtr hwnd, int x, int y, CancellationToken cancellationToken);
    Task<string?> ResizeAsync(IntPtr hwnd, int width, int height, CancellationToken cancellationToken);
    Task<string?> SetStateAsync(IntPtr hwnd, WindowState state, CancellationToken cancellationToken);
    Task<string?> SwitchAppAsync(string process, CancellationToken cancellationToken);
}

public interface IInputAutomationSurface
{
    Task<string?> SendShortcutAsync(string accelerator, CancellationToken cancellationToken);
    Task<string?> TypeAsync(string text, CancellationToken cancellationToken);
    Task<string?> PasteAsync(string text, CancellationToken cancellationToken);
    Task<string?> PressKeyAsync(string key, CancellationToken cancellationToken);
    Task<string?> MoveCursorAsync(int x, int y, CancellationToken cancellationToken);
    Task<string?> ClickAsync(int x, int y, MouseButtonKind button, int count, CancellationToken cancellationToken);
    Task<string?> ScrollAsync(int dx, int dy, CancellationToken cancellationToken);
}

public interface IFileAutomationSurface
{
    Task<string?> OpenAppAsync(string executable, string? arguments, CancellationToken cancellationToken);
    Task<string?> OpenFileAsync(string path, CancellationToken cancellationToken);
    Task<string?> RevealAsync(string path, CancellationToken cancellationToken);
    Task<string?> CreateDraftAsync(string path, string content, bool overwrite, CancellationToken cancellationToken);
}

public interface IBrowserCommandSurface
{
    /// <summary>True when a browser extension is currently connected and authenticated.</summary>
    bool IsAvailable { get; }

    /// <summary>Fire-and-forget send. Returns null on success, error message otherwise.</summary>
    Task<string?> SendAsync(BrowserCommand command, CancellationToken cancellationToken);

    /// <summary>Send and await the extension's ack. The executor only marks a browser
    /// intent <c>Succeeded</c> when <see cref="BrowserAck.Completed"/> is true.</summary>
    Task<BrowserAck> SendWithAckAsync(BrowserCommand command, TimeSpan timeout, CancellationToken cancellationToken);
}

/// <summary>
/// Wire payload sent from host → extension. <see cref="CommandId"/> identifies the
/// matching ack frame. New optional fields default to null and are stripped on the wire.
/// </summary>
public sealed record BrowserCommand(
    string Type,
    string? CommandId = null,
    string? Url = null,
    string? Selector = null,
    int? Dy = null);

/// <summary>Extension's reply to a host command. The host treats the action as completed
/// only when <see cref="Completed"/> is true.</summary>
public sealed record BrowserAck(
    string CommandId,
    bool Accepted,
    bool Completed,
    string? Error = null,
    string? ResultingUrl = null,
    string? ResultingTitle = null,
    int? Matches = null,
    string? Sample = null,
    /// <summary>Populated by the <c>listTargets</c> command — one entry per visible
    /// interactive element the extension found in the active tab.</summary>
    IReadOnlyList<BrowserDomTarget>? Targets = null,

    /// <summary>Viewport metadata returned with <c>listTargets</c> so the host can map
    /// CSS-pixel target rects to screen pixels without guessing chrome offsets.</summary>
    BrowserViewport? Viewport = null)
{
    public static BrowserAck Timeout(string commandId) =>
        new(commandId, Accepted: false, Completed: false, Error: "timeout");
    public static BrowserAck Disconnected(string commandId) =>
        new(commandId, Accepted: false, Completed: false, Error: "extension disconnected");
}

/// <summary>One target returned by the extension's <c>listTargets</c> handler. Bounds
/// are in CSS pixels relative to the tab viewport; the host maps them to screen pixels.</summary>
public sealed record BrowserDomTarget(
    string Label,
    string Role,
    string Selector,
    double X,
    double Y,
    double Width,
    double Height,
    bool Visible,
    bool Enabled);

/// <summary>Per-tab viewport metadata. <see cref="ScreenX"/>/<see cref="ScreenY"/> are
/// the top-left of the *page viewport* in screen pixels (i.e. the area where DOM content
/// renders, excluding tab strip + address bar). <see cref="DevicePixelRatio"/> is
/// <c>window.devicePixelRatio</c>; multiply CSS pixels by this to get screen pixels.</summary>
public sealed record BrowserViewport(
    int ScreenX,
    int ScreenY,
    int Width,
    int Height,
    double DevicePixelRatio,
    int ScrollX,
    int ScrollY);
