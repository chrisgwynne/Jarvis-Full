using System.Diagnostics;
using Jarvis.Core.Settings;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Closes a running application, either gracefully or by force.
/// Respects <see cref="ToolsSettings.AllowAppClose"/> and <see cref="ToolsSettings.AllowForceClose"/>.
/// </summary>
public sealed class CloseAppTool : IWindowsTool
{
    private readonly Func<ToolsSettings> _settings;

    public CloseAppTool(Func<ToolsSettings> settings)
    {
        _settings = settings;
    }

    public string Name => "close_app";
    public IReadOnlyList<string> Aliases { get; } = ["close", "quit_app"];
    public string Description => "Closes a running application gracefully (or by force if requested).";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Confirm;

    public async Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        var settings = _settings();

        if (!settings.AllowAppClose)
        {
            return Blocked("App close is disabled in settings.");
        }

        if (!request.Parameters.TryGetValue("app", out var app) || string.IsNullOrWhiteSpace(app))
        {
            return Fail("Parameter 'app' is required.");
        }

        var forceParam = request.Parameters.TryGetValue("force", out var fp) && fp.Equals("true", StringComparison.OrdinalIgnoreCase);

        if (forceParam && !settings.AllowForceClose)
        {
            return Blocked("Force close is disabled in settings. Enable Settings.Tools.AllowForceClose to use this.");
        }

        var processName = FocusAppTool.ResolveProcessName(app.Trim());
        var processes = Process.GetProcessesByName(processName);

        if (processes.Length == 0)
        {
            return Fail($"{app} does not appear to be running.");
        }

        if (request.DryRun)
        {
            var mode = forceParam ? "force kill" : "graceful close";
            foreach (var p in processes) p.Dispose();
            return Ok($"Would {mode} {app} (dry run)");
        }

        var killed = 0;
        var errors = new List<string>();

        foreach (var process in processes)
        {
            try
            {
                if (forceParam)
                {
                    process.Kill();
                    killed++;
                }
                else
                {
                    var sent = process.CloseMainWindow();
                    if (sent)
                    {
                        // Wait up to 2 seconds for graceful exit
                        var exited = await Task.Run(() => process.WaitForExit(2000), ct).ConfigureAwait(false);
                        killed++;
                    }
                    else
                    {
                        errors.Add($"Process {process.Id} has no main window — use force=true to kill.");
                    }
                }
            }
            catch (Exception ex)
            {
                errors.Add(ex.Message);
            }
            finally
            {
                process.Dispose();
            }
        }

        if (killed > 0)
        {
            var detail = errors.Count > 0 ? $"Closed {killed} process(es). Warnings: {string.Join("; ", errors)}" : null;
            return new WindowsToolResult(true, $"Closed {app}", detail, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
        }

        return Fail(errors.Count > 0 ? errors[0] : $"Could not close {app}.");
    }

    private static WindowsToolResult Ok(string summary) =>
        new(true, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);

    private static WindowsToolResult Blocked(string summary) =>
        new(false, summary, "Blocked by settings policy.", null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
}
