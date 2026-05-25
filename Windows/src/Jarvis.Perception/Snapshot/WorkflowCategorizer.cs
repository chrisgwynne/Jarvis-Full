using Jarvis.Core.Perception;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Snapshot;

/// <summary>
/// Maps raw observation inputs to a coarse workflow category. Rule-based — when the same
/// inputs come back to back the answer is stable, so callers can hash-cache snapshots.
///
/// Priority order (highest first): Debugging > Coding > TerminalWork > Gaming > Browsing > Communication > Writing > Reading > Media > Shopping > Editing > Idle.
/// </summary>
public sealed class WorkflowCategorizer : IWorkflowCategorizer
{
    internal static readonly HashSet<string> IdeProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Code", "Code - Insiders", "Cursor", "devenv", "rider64", "idea64", "pycharm64",
        "webstorm64", "clion64", "goland64", "sublime_text", "atom", "notepad++", "vim", "nvim", "emacs",
        "windsurf", "zed", "helix", "lapce"
    };
    private static readonly HashSet<string> IdeProcesses = IdeProcessNames;

    internal static readonly HashSet<string> BrowserProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "msedge", "firefox", "brave", "opera", "arc", "vivaldi",
        "thorium", "librewolf", "brave-browser", "zen"
    };
    private static readonly HashSet<string> BrowserProcesses = BrowserProcessNames;

    internal static readonly HashSet<string> TerminalProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "cmd", "powershell", "pwsh", "wt", "ConEmu64", "alacritty", "wezterm-gui"
    };
    private static readonly HashSet<string> TerminalProcesses = TerminalProcessNames;

    internal static readonly HashSet<string> CommsProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "slack", "Teams", "Discord", "WhatsApp", "Telegram", "outlook", "Spark", "thunderbird",
        "zoom", "webex", "Signal", "element", "wire", "mattermost"
    };
    private static readonly HashSet<string> CommsProcesses = CommsProcessNames;

    internal static readonly HashSet<string> EditingProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Photoshop", "Illustrator", "AfterFX", "Premiere", "Resolve", "Figma", "Sketch", "Affinity Photo", "Affinity Designer",
        "Blender", "Krita", "inkscape", "darktable", "RawTherapee", "obs64", "obs32", "obs"
    };
    private static readonly HashSet<string> EditingProcesses = EditingProcessNames;

    internal static readonly HashSet<string> MediaProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "vlc", "Spotify", "Music.UI", "wmplayer", "mpv", "potplayer",
        "Netflix", "PrimeVideo", "YouTubeApp", "AppleMusic", "PodcastsApp"
    };
    private static readonly HashSet<string> MediaProcesses = MediaProcessNames;

    internal static readonly HashSet<string> WritingProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WINWORD", "notion", "obsidian", "Typora", "Bear", "Ulysses", "scrivener"
    };
    private static readonly HashSet<string> WritingProcesses = WritingProcessNames;

    internal static readonly HashSet<string> GamingProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "steam", "EpicGamesLauncher", "gameoverlayui", "RiotClientServices", "LeagueClient",
        "Minecraft.Windows", "javaw", "destiny2", "Warzone", "csgo", "dota2", "valorant",
        "RocketLeague", "overwatch", "fortnite"
    };
    // Backward-compat alias (was 'GamingProcesses' — now exposed as GamingProcessNames for consistency)
    internal static readonly HashSet<string> GamingProcesses = GamingProcessNames;

    public WorkflowCategory Categorize(SemanticSnapshotInputs inputs)
    {
        if (inputs.Desktop is null) return WorkflowCategory.Unknown;
        if (!inputs.Desktop.IsUserActive) return WorkflowCategory.Idle;

        var app = inputs.Desktop.ForegroundProcessName ?? string.Empty;
        var selType = inputs.Selection?.HasSelection == true ? Classify(inputs.Selection.Text) : SemanticContentType.Unknown;
        var clipType = inputs.Clipboard?.ContentType ?? SemanticContentType.Unknown;

        // Debugging: stack-trace in selection/clipboard, in any IDE context.
        if ((selType == SemanticContentType.StackTrace || clipType == SemanticContentType.StackTrace)
            && (IdeProcesses.Contains(app) || TerminalProcesses.Contains(app)))
            return WorkflowCategory.Debugging;

        if (IdeProcesses.Contains(app)) return WorkflowCategory.Coding;
        if (TerminalProcesses.Contains(app)) return WorkflowCategory.TerminalWork;
        if (GamingProcesses.Contains(app)) return WorkflowCategory.Gaming;
        if (BrowserProcesses.Contains(app))
        {
            // research vs general browsing: very long-form pages or selected prose lean toward research
            if (selType is SemanticContentType.Prose or SemanticContentType.Markdown
                && (inputs.Selection?.Text?.Length ?? 0) > 200)
                return WorkflowCategory.Research;
            // shopping if URL or title hints at it
            var url = inputs.Browser?.Url ?? string.Empty;
            var title = inputs.Browser?.Title ?? string.Empty;
            if (UrlOrTitleHas(url, title, "amazon", "ebay", "etsy", "shopify", "checkout", "cart", "shop"))
                return WorkflowCategory.Shopping;
            return WorkflowCategory.Browsing;
        }
        if (CommsProcesses.Contains(app)) return WorkflowCategory.Communication;
        if (EditingProcesses.Contains(app)) return WorkflowCategory.Editing;
        if (MediaProcesses.Contains(app)) return WorkflowCategory.Media;
        if (WritingProcesses.Contains(app)) return WorkflowCategory.Writing;

        return WorkflowCategory.Unknown;
    }

    private static SemanticContentType Classify(string? _) => SemanticContentType.Unknown; // intentionally not classifying here

    private static bool UrlOrTitleHas(string url, string title, params string[] needles)
    {
        foreach (var n in needles)
        {
            if (url.Contains(n, StringComparison.OrdinalIgnoreCase)) return true;
            if (title.Contains(n, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }
}
