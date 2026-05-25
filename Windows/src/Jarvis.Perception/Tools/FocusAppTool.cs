using System.Diagnostics;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Brings a running application to the foreground. Uses the same alias table as OpenAppTool.
/// Returns a failure result if the process is not currently running.
/// </summary>
public sealed class FocusAppTool : IWindowsTool
{
    public string Name => "focus_app";
    public IReadOnlyList<string> Aliases { get; } = ["focus", "bring_to_front", "switch_to"];
    public string Description => "Brings a running application to the foreground.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Safe;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (!request.Parameters.TryGetValue("app", out var app) || string.IsNullOrWhiteSpace(app))
        {
            return Task.FromResult(Fail("Parameter 'app' is required."));
        }

        // Resolve alias to executable name (strip .exe extension for GetProcessesByName)
        var processName = ResolveProcessName(app.Trim());

        // GetProcessesByName does not use the .exe extension
        var processes = Process.GetProcessesByName(processName);
        if (processes.Length == 0)
        {
            return Task.FromResult(Fail($"{app} does not appear to be running."));
        }

        if (request.DryRun)
        {
            return Task.FromResult(Ok($"{app} is running (dry run — would bring to front)"));
        }

        // Find process with a main window
        var target = processes.FirstOrDefault(p => p.MainWindowHandle != IntPtr.Zero);
        if (target is null)
        {
            return Task.FromResult(Fail($"{app} is running but has no visible window to focus."));
        }

        var hwnd = target.MainWindowHandle;
        var success = Win32Helpers.SetForegroundWindow(hwnd);

        foreach (var p in processes) p.Dispose();

        return Task.FromResult(success
            ? Ok($"Focused {app}")
            : Fail($"Could not bring {app} to the foreground (OS restriction)."));
    }

    /// <summary>
    /// Resolves a friendly alias to a process name (without .exe).
    /// If the alias is not in the map, returns the input stripped of any .exe suffix.
    /// </summary>
    internal static string ResolveProcessName(string alias)
    {
        if (OpenAppTool.AliasMap.TryGetValue(alias, out var exe))
        {
            // Strip .exe for GetProcessesByName
            return exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? exe[..^4]
                : exe;
        }
        // Treat as direct process name
        return alias.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? alias[..^4]
            : alias;
    }

    private static WindowsToolResult Ok(string summary) =>
        new(true, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
}
