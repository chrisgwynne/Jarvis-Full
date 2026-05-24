using System.IO;
using Jarvis.Core.Automation;

namespace Jarvis.Automation;

/// <summary>
/// Conservative defaults. Bias: when in doubt, require <see cref="SafetyTier.Approve"/>.
/// Tests pin this surface so users can rely on "I never typed without seeing the prompt".
///
/// Update philosophy: never lower a tier in a patch release. Lowering is a policy change
/// the user must opt into via settings (not implemented in P3 — every demotion happens
/// in code review here).
/// </summary>
public sealed class DefaultApprovalPolicy : IApprovalPolicy
{
    public const string Identifier = "default/1.0.0";
    public string Version => Identifier;

    public SafetyDecision Classify(AutomationIntent intent)
    {
        // ── 1) Hard blocks (deny-list) ───────────────────────────────────────
        if (LooksLikeDestructiveShellCommand(intent) is { } blockReason)
            return new SafetyDecision(SafetyTier.Block, "destructive shell pattern", blockReason);

        if (intent is BrowserNavigateIntent nav && !IsSafeUrl(nav.Url))
            return new SafetyDecision(SafetyTier.Block, "unsafe URL scheme", $"only http(s) URLs allowed, got: {nav.Url}");

        if (intent is OpenAppIntent app && IsPrivilegedExecutable(app.Executable))
            return new SafetyDecision(SafetyTier.Block, "privileged executable", $"refusing to launch {app.Executable}");

        if (intent is CreateDraftFileIntent draft && IsProtectedPath(draft.Path))
            return new SafetyDecision(SafetyTier.Block, "protected path", $"refusing to write inside {draft.Path}");

        // ── 2) Tier assignment ───────────────────────────────────────────────
        return intent switch
        {
            // Read-mostly / trivially reversible
            FocusWindowIntent => Safe("focus changes are reversible (Alt-Tab back)"),
            SwitchAppIntent   => Safe("focus changes are reversible (Alt-Tab back)"),
            SetWindowStateIntent => Safe("window state toggle is reversible"),
            MoveCursorIntent => Safe("cursor moves don't change app state"),
            HighlightTargetIntent => Safe("overlay-only highlight"),
            ScrollIntent => Safe("scroll doesn't change app state"),
            BrowserScrollIntent => Safe("browser scroll doesn't change page state"),
            BrowserExtractSelectionIntent => Safe("read-only DOM read"),
            RevealFileIntent => Safe("opens Explorer at path; no file content change"),

            // Modify state but low-blast-radius — Confirm tier
            MoveWindowIntent => Confirm("window move"),
            ResizeWindowIntent => Confirm("window resize"),
            PressKeyIntent k when IsNavigationKey(k.Key) => Confirm("navigation key"),
            SendShortcutIntent s when IsBenignShortcut(s.Accelerator) => Confirm($"shortcut {s.Accelerator}"),
            BrowserHistoryIntent => Confirm("browser history nav"),
            BrowserNavigateIntent => Confirm("browser navigation (whitelisted scheme)"),
            BrowserReloadIntent => Confirm("page reload"),
            BrowserFocusInputIntent => Confirm("focus a browser input"),

            // Side effects requiring explicit approval
            TypeTextIntent => Approve("synthesises keystrokes into the foreground app"),
            PasteTextIntent => Approve("pastes into the foreground app"),
            PressKeyIntent => Approve("non-navigation keypress"),
            SendShortcutIntent => Approve("non-benign shortcut"),
            ClickIntent => Approve("synthesises a mouse click"),
            BrowserClickSelectorIntent => Approve("clicks a DOM selector"),
            OpenAppIntent => Approve("launches an app"),
            OpenFileIntent => Approve("opens a file with its default app"),
            CreateDraftFileIntent { Overwrite: true } => Approve("overwrites an existing file"),
            CreateDraftFileIntent => Approve("creates a file"),

            _ => Approve($"unclassified intent: {intent.Kind}")
        };
    }

    private static SafetyDecision Safe(string reason) => new(SafetyTier.Safe, reason);
    private static SafetyDecision Confirm(string reason) => new(SafetyTier.Confirm, reason);
    private static SafetyDecision Approve(string reason) => new(SafetyTier.Approve, reason);

    // ── Deny-list helpers ───────────────────────────────────────────────────

    private static readonly string[] DangerousArgPatterns =
    {
        "rm -rf", "rm /", "rmdir /s", "del /f /s /q", "format ", "shutdown /s", "shutdown /r",
        "diskpart", "cipher /w", "fdisk", "bootrec", "bcdedit",
        " /quiet /norestart", "Invoke-Expression", "iex ", "DownloadString"
    };

    internal static string? LooksLikeDestructiveShellCommand(AutomationIntent intent)
    {
        var haystack = intent switch
        {
            OpenAppIntent a => $"{a.Executable} {a.Arguments}",
            TypeTextIntent t => t.Text,
            PasteTextIntent p => p.Text,
            _ => null
        };
        if (haystack is null) return null;
        foreach (var pattern in DangerousArgPatterns)
            if (haystack.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                return $"matched pattern: '{pattern}'";
        return null;
    }

    internal static bool IsSafeUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url)) return false;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        return uri.Scheme == "http" || uri.Scheme == "https";
    }

    private static readonly string[] PrivilegedExeNames =
    {
        "cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe",
        "wscript", "cscript", "regedit", "mmc", "msconfig",
        "diskpart", "format", "bootrec", "bcdedit", "cipher"
    };

    internal static bool IsPrivilegedExecutable(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return true;
        var name = Path.GetFileName(path).ToLowerInvariant();
        foreach (var n in PrivilegedExeNames)
            if (name == n || name == n + ".exe") return true;
        return false;
    }

    internal static bool IsProtectedPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return true;
        string normalized;
        try { normalized = Path.GetFullPath(path); }
        catch { return true; }
        var lower = normalized.ToLowerInvariant();
        return lower.StartsWith(@"c:\windows", StringComparison.Ordinal)
            || lower.StartsWith(@"c:\program files", StringComparison.Ordinal)
            || lower.StartsWith(@"c:\programdata", StringComparison.Ordinal)
            || lower.Contains(@"\system32\", StringComparison.Ordinal);
    }

    // ── Tier helpers ────────────────────────────────────────────────────────

    private static readonly HashSet<string> NavigationKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End", "Tab", "Escape"
    };

    internal static bool IsNavigationKey(string key) => NavigationKeys.Contains(key);

    private static readonly HashSet<string> BenignShortcuts = new(StringComparer.OrdinalIgnoreCase)
    {
        // Read-only / navigation-only chords
        "Ctrl+C", "Ctrl+A", "Ctrl+F", "Ctrl+L", "Ctrl+T", "Ctrl+Tab", "Ctrl+Shift+Tab",
        "Alt+Tab", "Alt+Left", "Alt+Right"
    };

    internal static bool IsBenignShortcut(string accelerator) => BenignShortcuts.Contains(accelerator);
}
