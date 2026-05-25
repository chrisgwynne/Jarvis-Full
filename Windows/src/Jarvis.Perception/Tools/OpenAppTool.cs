using System.ComponentModel;
using System.Diagnostics;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Opens a named application. Resolves friendly aliases to executable names before
/// launching. Never shells arbitrary strings — only allowlisted aliases resolve.
/// </summary>
public sealed class OpenAppTool : IWindowsTool
{
    // Alias → executable or shell URI (case-insensitive lookup)
    internal static readonly IReadOnlyDictionary<string, string> AliasMap =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["chrome"]          = "chrome.exe",
            ["edge"]            = "msedge.exe",
            ["firefox"]         = "firefox.exe",
            ["vscode"]          = "code.exe",
            ["code"]            = "code.exe",
            ["cursor"]          = "cursor.exe",
            ["visual studio"]   = "devenv.exe",
            ["spotify"]         = "Spotify.exe",
            ["steam"]           = "steam.exe",
            ["discord"]         = "Discord.exe",
            ["teams"]           = "Teams.exe",
            ["outlook"]         = "OUTLOOK.EXE",
            ["notepad"]         = "notepad.exe",
            ["calculator"]      = "calc.exe",
            ["settings"]        = "ms-settings:",
            ["explorer"]        = "explorer.exe",
            ["paint"]           = "mspaint.exe",
            ["terminal"]        = "wt.exe",
            ["powershell"]      = "pwsh.exe",
        };

    public string Name => "open_app";
    public IReadOnlyList<string> Aliases { get; } = ["open", "launch", "start_app"];
    public string Description => "Opens a named application by alias.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Confirm;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (!request.Parameters.TryGetValue("app", out var app) || string.IsNullOrWhiteSpace(app))
        {
            return Task.FromResult(Fail("Parameter 'app' is required."));
        }

        if (!AliasMap.TryGetValue(app.Trim(), out var resolved))
        {
            return Task.FromResult(Fail(
                $"Unknown app '{app}'. Use a known alias or full executable name. Known aliases: {string.Join(", ", AliasMap.Keys.OrderBy(k => k))}"));
        }

        if (request.DryRun)
        {
            return Task.FromResult(Ok($"Would open {resolved}", $"Dry run: would launch '{resolved}' for alias '{app}'"));
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = resolved,
                UseShellExecute = true
            });
            return Task.FromResult(Ok($"Opened {app}", $"Launched '{resolved}'"));
        }
        catch (Win32Exception ex)
        {
            return Task.FromResult(Fail($"Failed to open '{app}': {ex.Message}"));
        }
        catch (InvalidOperationException ex)
        {
            return Task.FromResult(Fail($"Failed to open '{app}': {ex.Message}"));
        }
        catch (Exception ex)
        {
            return Task.FromResult(Fail($"Unexpected error launching '{app}': {ex.GetType().Name}"));
        }
    }

    private static WindowsToolResult Ok(string summary, string? detail = null) =>
        new(true, summary, detail, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
}
