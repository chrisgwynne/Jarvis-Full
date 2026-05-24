using System.IO;
using System.Text.RegularExpressions;
using Jarvis.Core.Awareness;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Perception;
using Microsoft.Extensions.Logging;

namespace Jarvis.Perception.Ide;

/// <summary>
/// Best-effort IDE context derived from the foreground process + window title, plus a
/// small <c>.git</c> walk to recover repo root and branch. Does not require any IDE
/// extension — it works for VS Code, Cursor, JetBrains (Rider/IntelliJ/PyCharm/...),
/// Visual Studio, Sublime, Notepad++, vim/neovim/emacs in a terminal.
///
/// Title parsing is intentionally conservative: if we can't be confident, we leave the
/// field null so downstream consumers don't act on bad data.
///
/// Caching: repo root lookup is hashed by ProjectRoot path, so a long-lived editor
/// session only walks the filesystem once per project.
/// </summary>
public sealed partial class WindowTitleIdeContextProvider : IIdeContextProvider
{
    private readonly Func<DesktopSnapshot?> _desktopSnapshot;
    private readonly IDiagnostics? _diagnostics;
    private readonly ILogger<WindowTitleIdeContextProvider>? _logger;
    private readonly Dictionary<string, (string? Repo, string? Branch)> _repoCache = new(StringComparer.OrdinalIgnoreCase);

    public WindowTitleIdeContextProvider(
        Func<DesktopSnapshot?> desktopSnapshot,
        IDiagnostics? diagnostics = null,
        ILogger<WindowTitleIdeContextProvider>? logger = null)
    {
        _desktopSnapshot = desktopSnapshot;
        _diagnostics = diagnostics;
        _logger = logger;
    }

    public IdeContext TryReadContext()
    {
        var snap = _desktopSnapshot();
        if (snap is null) return IdeContext.Empty;
        var process = snap.ForegroundProcessName ?? string.Empty;
        var title = snap.ForegroundWindowTitle ?? string.Empty;

        var editor = MapEditor(process);
        if (editor is null) return IdeContext.Empty with { CapturedAt = DateTimeOffset.UtcNow };

        var (activeFile, projectRoot) = ParseTitle(editor, title);
        var (repoRoot, branch) = ResolveRepo(projectRoot ?? Path.GetDirectoryName(activeFile));

        return new IdeContext(
            CapturedAt: DateTimeOffset.UtcNow,
            Editor: editor,
            ActiveFile: activeFile,
            ProjectRoot: projectRoot,
            RepoRoot: repoRoot,
            Branch: branch,
            ProviderSupported: true);
    }

    internal static string? MapEditor(string process) => process.ToLowerInvariant() switch
    {
        "code" or "code - insiders" => "VS Code",
        "cursor" => "Cursor",
        "devenv" => "Visual Studio",
        "rider64" or "rider" => "Rider",
        "idea64" or "idea" => "IntelliJ IDEA",
        "pycharm64" or "pycharm" => "PyCharm",
        "webstorm64" or "webstorm" => "WebStorm",
        "clion64" or "clion" => "CLion",
        "goland64" or "goland" => "GoLand",
        "phpstorm64" or "phpstorm" => "PhpStorm",
        "sublime_text" => "Sublime Text",
        "notepad++" => "Notepad++",
        _ => null
    };

    [GeneratedRegex(@"^(?<file>[^●•]+?)\s+[●•]?\s*(?:-\s*(?<folder>.+?)\s+)?-\s+(?:Visual Studio Code|Cursor|VSCodium)(?:\s*-\s*Insiders)?\s*$",
        RegexOptions.Compiled)]
    private static partial Regex VsCodeTitle();

    [GeneratedRegex(@"^(?<folder>.+?)\s*[-–]\s*(?<file>[^-–]+?)\s*(?:\(.*?\))?\s*$", RegexOptions.Compiled)]
    private static partial Regex JetBrainsTitle();

    [GeneratedRegex(@"^(?<file>.+?)\s*-\s*Microsoft Visual Studio\b.*$", RegexOptions.Compiled)]
    private static partial Regex VisualStudioTitle();

    /// <summary>Parse the window title for the active file + project root.
    /// Returns nulls when the title format isn't recognised.</summary>
    internal static (string? ActiveFile, string? ProjectRoot) ParseTitle(string editor, string title)
    {
        if (string.IsNullOrEmpty(title)) return (null, null);

        if (editor is "VS Code" or "Cursor")
        {
            var m = VsCodeTitle().Match(title);
            if (m.Success)
            {
                var file = Trim(m.Groups["file"].Value);
                var folder = Trim(m.Groups["folder"].Value);
                return (file, folder.Length > 0 ? folder : null);
            }
        }

        if (editor is "Rider" or "IntelliJ IDEA" or "PyCharm" or "WebStorm" or "CLion" or "GoLand" or "PhpStorm")
        {
            var m = JetBrainsTitle().Match(title);
            if (m.Success)
            {
                var folder = Trim(m.Groups["folder"].Value);
                var file = Trim(m.Groups["file"].Value);
                return (file, folder);
            }
        }

        if (editor is "Visual Studio")
        {
            var m = VisualStudioTitle().Match(title);
            if (m.Success) return (Trim(m.Groups["file"].Value), null);
        }

        // Sublime / Notepad++: title looks like "filename.ext - folder - Sublime Text" or "* C:\path\file.ext - Notepad++"
        var dash = title.IndexOf(" - ", StringComparison.Ordinal);
        if (dash > 0)
        {
            var leading = Trim(title[..dash].TrimStart('*', ' '));
            return (leading, null);
        }
        return (null, null);
    }

    private static string Trim(string s) => s.Trim().Trim('●', '•', ' ', '*');

    private (string? RepoRoot, string? Branch) ResolveRepo(string? startDir)
    {
        if (string.IsNullOrEmpty(startDir)) return (null, null);
        if (_repoCache.TryGetValue(startDir, out var cached)) return cached;

        try
        {
            var dir = Directory.Exists(startDir) ? new DirectoryInfo(startDir) : new FileInfo(startDir).Directory;
            while (dir is not null)
            {
                var git = Path.Combine(dir.FullName, ".git");
                if (Directory.Exists(git))
                {
                    var head = Path.Combine(git, "HEAD");
                    string? branch = null;
                    if (File.Exists(head))
                    {
                        var content = File.ReadAllText(head).Trim();
                        // "ref: refs/heads/main" → "main", or a detached SHA → first 7 chars
                        if (content.StartsWith("ref: refs/heads/", StringComparison.Ordinal))
                            branch = content["ref: refs/heads/".Length..];
                        else if (content.Length >= 7)
                            branch = content[..Math.Min(content.Length, 12)];
                    }
                    var result = (dir.FullName, branch);
                    _repoCache[startDir] = result;
                    return result;
                }
                dir = dir.Parent;
            }
        }
        catch (Exception ex)
        {
            _logger?.LogDebug(ex, "Repo lookup failed for {Path}", startDir);
            _diagnostics?.Record(DiagnosticLevel.Debug, "ide", "repo lookup failed",
                new Dictionary<string, object?> { ["path"] = startDir, ["error"] = ex.Message });
        }
        var miss = ((string?)null, (string?)null);
        _repoCache[startDir] = miss;
        return miss;
    }
}
