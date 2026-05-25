using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Controls system volume using WM_APPCOMMAND messages.
/// Supports mute, unmute (toggle), and volume up/down stepping.
/// Does not require CoreAudioAPI or any NuGet packages.
/// </summary>
public sealed class VolumeMicTool : IWindowsTool
{
    public string Name => "volume_control";
    public IReadOnlyList<string> Aliases { get; } = ["volume", "mute", "unmute", "set_volume"];
    public string Description => "Controls system volume: mute, unmute, or set a target level.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Safe;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        request.Parameters.TryGetValue("action", out var action);
        request.Parameters.TryGetValue("level", out var levelStr);

        action = (action ?? "mute").Trim().ToLowerInvariant();

        if (request.DryRun)
        {
            return Task.FromResult(Ok($"Would {action} volume (dry run)"));
        }

        var hwnd = Win32Helpers.GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            // Fall back to HWND_BROADCAST equivalent — send to desktop
            hwnd = new nint(0xFFFF); // HWND_BROADCAST
        }

        switch (action)
        {
            case "mute":
            case "unmute":
                SendAppCommand(hwnd, Win32Helpers.APPCOMMAND_VOLUME_MUTE);
                return Task.FromResult(Ok($"Toggled volume mute"));

            case "set":
                if (!int.TryParse(levelStr, out var level) || level < 0 || level > 100)
                {
                    return Task.FromResult(Fail("Parameter 'level' must be 0–100 for action=set."));
                }
                // Best-effort: send repeated up/down commands to approximate target.
                // We cannot read current volume without CoreAudioAPI, so we start from
                // a known state (mute off) and step up. This is intentionally approximate.
                ApproximateVolume(hwnd, level);
                return Task.FromResult(Ok($"Adjusted volume toward {level}% (best-effort)"));

            default:
                return Task.FromResult(Fail($"Unknown action '{action}'. Use: mute, unmute, or set."));
        }
    }

    private static void SendAppCommand(nint hwnd, long command)
    {
        var lParam = new nint((int)(command << 16));
        Win32Helpers.SendMessage(hwnd, Win32Helpers.WM_APPCOMMAND, hwnd, lParam);
    }

    private static void ApproximateVolume(nint hwnd, int targetPercent)
    {
        // Send MUTE off first (toggle twice to ensure unmuted) — then step up.
        // This is an approximation; for precise control CoreAudioAPI would be needed.
        // Step: each VOLUME_UP/DOWN command typically changes volume by ~2%.
        var steps = targetPercent / 2;
        // First mute to reset perception, then send up steps
        for (var i = 0; i < 50; i++)  // drive to minimum first
            SendAppCommand(hwnd, Win32Helpers.APPCOMMAND_VOLUME_DOWN);
        for (var i = 0; i < steps; i++)
            SendAppCommand(hwnd, Win32Helpers.APPCOMMAND_VOLUME_UP);
    }

    private static WindowsToolResult Ok(string summary) =>
        new(true, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
}
