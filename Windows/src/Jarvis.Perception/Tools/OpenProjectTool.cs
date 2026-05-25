using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Jarvis.Core.Settings;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Opens a project folder by alias. Reads project shortcuts from
/// %APPDATA%\Jarvis\projects.json (if present) and falls back to settings-defined aliases.
/// Never opens arbitrary paths — only allowlisted alias-to-path mappings.
/// </summary>
public sealed class OpenProjectTool : IWindowsTool
{
    private static readonly string ProjectsFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Jarvis", "projects.json");

    private readonly Func<ProjectSettings> _projectSettings;

    public OpenProjectTool(Func<ProjectSettings> projectSettings)
    {
        _projectSettings = projectSettings;
    }

    public string Name => "open_project";
    public IReadOnlyList<string> Aliases { get; } = ["project", "open_repo", "open_folder"];
    public string Description => "Opens a project folder by alias, optionally launching an IDE.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Confirm;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (!request.Parameters.TryGetValue("project", out var projectAlias) || string.IsNullOrWhiteSpace(projectAlias))
        {
            return Task.FromResult(Fail("Parameter 'project' is required."));
        }

        var aliases = LoadAliases();
        if (aliases.Count == 0)
        {
            return Task.FromResult(Fail(
                $"No project aliases configured. Add them to '{ProjectsFilePath}' or to Settings.Projects.Aliases."));
        }

        var match = aliases.FirstOrDefault(a =>
            string.Equals(a.Alias, projectAlias.Trim(), StringComparison.OrdinalIgnoreCase));

        if (match is null)
        {
            var knownList = string.Join(", ", aliases.Select(a => a.Alias));
            return Task.FromResult(Fail($"Unknown project alias '{projectAlias}'. Known aliases: {knownList}"));
        }

        if (!Directory.Exists(match.Path))
        {
            return Task.FromResult(Fail($"Project path '{match.Path}' does not exist."));
        }

        if (request.DryRun)
        {
            return Task.FromResult(Ok($"Would open project '{match.Alias}' at '{match.Path}'" +
                (match.App is not null ? $" with {match.App}" : " in Explorer")));
        }

        try
        {
            if (match.App is not null && OpenAppTool.AliasMap.TryGetValue(match.App, out var appExe))
            {
                // Open with specific app
                Process.Start(new ProcessStartInfo
                {
                    FileName = appExe,
                    Arguments = $"\"{match.Path}\"",
                    UseShellExecute = true
                });
                return Task.FromResult(Ok($"Opened '{match.Alias}' in {match.App}"));
            }
            else
            {
                // Open in Explorer
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"\"{match.Path}\"",
                    UseShellExecute = true
                });
                return Task.FromResult(Ok($"Opened '{match.Alias}' folder in Explorer"));
            }
        }
        catch (Win32Exception ex)
        {
            return Task.FromResult(Fail($"Failed to open project '{projectAlias}': {ex.Message}"));
        }
        catch (Exception ex)
        {
            return Task.FromResult(Fail($"Unexpected error opening project '{projectAlias}': {ex.GetType().Name}"));
        }
    }

    private List<ProjectAlias> LoadAliases()
    {
        var result = new List<ProjectAlias>();

        // 1. Load from projects.json if it exists
        if (File.Exists(ProjectsFilePath))
        {
            try
            {
                var json = File.ReadAllText(ProjectsFilePath);
                var fileAliases = JsonSerializer.Deserialize<ProjectAlias[]>(json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (fileAliases is not null)
                    result.AddRange(fileAliases);
            }
            catch
            {
                // Malformed projects.json — continue with settings-only
            }
        }

        // 2. Merge in settings-defined aliases (settings take lower priority than file)
        foreach (var settingsAlias in _projectSettings().Aliases)
        {
            if (!result.Any(r => string.Equals(r.Alias, settingsAlias.Alias, StringComparison.OrdinalIgnoreCase)))
                result.Add(settingsAlias);
        }

        return result;
    }

    private static WindowsToolResult Ok(string summary) =>
        new(true, summary, null, null, ToolPrivacyImpact.FilePath, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.FilePath, DateTimeOffset.UtcNow);
}
