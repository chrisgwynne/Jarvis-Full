namespace Jarvis.Core.Sidecar;

/// <summary>
/// Registry of Windows-local capabilities that can be executed via <c>execution.request</c>
/// from the Mac app. Only capabilities that are fully implemented and safe to advertise
/// are listed in <see cref="Enabled"/> — Windows must never claim capabilities it cannot deliver.
///
/// Each capability maps to one or more <see cref="Jarvis.Core.Automation.AutomationIntent"/>
/// kinds that the existing <c>RemoteExecutionBridge</c> / <c>IAutomationExecutor</c> handle.
/// </summary>
public static class WindowsCapabilities
{
    // ── Implemented capability identifiers ────────────────────────────────────
    public const string AppOpen             = "app.open";
    public const string NotificationDisplay = "notification.display";
    public const string FileSearch          = "file.search";
    public const string ScreenContext       = "screen.context";
    public const string ClipboardRead       = "clipboard.read";
    public const string ClipboardWrite      = "clipboard.write";
    public const string MediaPlay           = "media.play";
    public const string MediaPause          = "media.pause";
    public const string VolumeSet           = "volume.set";
    public const string SystemLock          = "system.lock";

    /// <summary>
    /// Capabilities currently enabled and safe to advertise to the daemon.
    /// This is the conservative list — items only graduate here when the full
    /// execution → approval → audit pipeline is in place for them.
    ///
    /// Note: capabilities that are "implemented" but require explicit user confirmation
    /// at execution time are safe to advertise because the approval gate still fires.
    /// Capabilities that could be destructive without approval are excluded until the
    /// policy coverage is confirmed.
    /// </summary>
    public static readonly IReadOnlyList<string> Enabled = new[]
    {
        AppOpen,        // window.focus / window.switchApp / app.open intents
        ScreenContext,  // OCR + foreground app context export
        ClipboardRead,  // clipboard.read intent
        ClipboardWrite  // keyboard.paste intent
    };

    /// <summary>True when <paramref name="capability"/> is in <see cref="Enabled"/>.</summary>
    public static bool IsEnabled(string capability) =>
        Enabled.Contains(capability, StringComparer.OrdinalIgnoreCase);
}
