namespace Jarvis.Core.Automation;

/// <summary>
/// Discriminated union of every action the AutomationExecutor knows how to perform.
/// Each concrete intent is an immutable record so the audit log can capture exactly
/// what was requested without aliasing later mutations.
///
/// Adding a new action: derive a sealed record, give it a stable <see cref="Kind"/>
/// string, register a tier in <see cref="IApprovalPolicy"/>, and add a dispatch arm
/// in the executor.
/// </summary>
public abstract record AutomationIntent
{
    /// <summary>Stable identifier used in the audit log and approval prompt.</summary>
    public abstract string Kind { get; }

    /// <summary>Short, human-readable summary. Lives on the base so the approval prompt
    /// can render any intent without a discriminator switch.</summary>
    public abstract string Summary { get; }
}

// ─── Window actions ──────────────────────────────────────────────────────────

public sealed record FocusWindowIntent(string Process, string? TitleSubstring = null) : AutomationIntent
{
    public override string Kind => "window.focus";
    public override string Summary => $"Bring {Process}{(TitleSubstring is null ? "" : $" ({TitleSubstring})")} to the foreground";
}

public sealed record MoveWindowIntent(IntPtr Hwnd, int X, int Y) : AutomationIntent
{
    public override string Kind => "window.move";
    public override string Summary => $"Move window {Hwnd} to ({X},{Y})";
}

public sealed record ResizeWindowIntent(IntPtr Hwnd, int Width, int Height) : AutomationIntent
{
    public override string Kind => "window.resize";
    public override string Summary => $"Resize window {Hwnd} to {Width}×{Height}";
}

public enum WindowState { Minimized, Maximized, Restored }

public sealed record SetWindowStateIntent(IntPtr Hwnd, WindowState State) : AutomationIntent
{
    public override string Kind => "window.state";
    public override string Summary => $"{State} window {Hwnd}";
}

public sealed record SwitchAppIntent(string Process) : AutomationIntent
{
    public override string Kind => "window.switchApp";
    public override string Summary => $"Switch to {Process}";
}

// ─── Keyboard actions ────────────────────────────────────────────────────────

public sealed record SendShortcutIntent(string Accelerator) : AutomationIntent
{
    public override string Kind => "keyboard.shortcut";
    public override string Summary => $"Press {Accelerator}";
}

public sealed record TypeTextIntent(string Text) : AutomationIntent
{
    public override string Kind => "keyboard.type";
    public override string Summary => $"Type {Preview(Text)}";

    public static string Preview(string text) =>
        text.Length <= 60 ? $"\"{text}\"" : $"\"{text[..60]}…\" ({text.Length} chars)";
}

public sealed record PasteTextIntent(string Text) : AutomationIntent
{
    public override string Kind => "keyboard.paste";
    public override string Summary => $"Paste {TypeTextIntent.Preview(Text)}";
}

public sealed record PressKeyIntent(string Key) : AutomationIntent
{
    public override string Kind => "keyboard.key";
    public override string Summary => $"Press {Key}";
}

// ─── Mouse / UI ──────────────────────────────────────────────────────────────

public enum MouseButtonKind { Left, Right, Middle }

public sealed record MoveCursorIntent(int X, int Y) : AutomationIntent
{
    public override string Kind => "mouse.move";
    public override string Summary => $"Move cursor to ({X},{Y})";
}

public sealed record ClickIntent(int X, int Y, MouseButtonKind Button = MouseButtonKind.Left, int Count = 1) : AutomationIntent
{
    public override string Kind => Count switch { 2 => "mouse.doubleClick", _ => "mouse.click" };
    public override string Summary => $"{Button} click ×{Count} at ({X},{Y})";
}

public sealed record ScrollIntent(int Dx, int Dy) : AutomationIntent
{
    public override string Kind => "mouse.scroll";
    public override string Summary => $"Scroll ({Dx},{Dy})";
}

public sealed record HighlightTargetIntent(int X, int Y, int Width, int Height, string? Label = null) : AutomationIntent
{
    public override string Kind => "ui.highlight";
    public override string Summary => Label is null
        ? $"Highlight rect {Width}×{Height} at ({X},{Y})"
        : $"Highlight {Label} at ({X},{Y})";
}

// ─── Browser (via extension) ─────────────────────────────────────────────────

public sealed record BrowserNavigateIntent(string Url) : AutomationIntent
{
    public override string Kind => "browser.navigate";
    public override string Summary => $"Navigate browser to {Url}";
}

public sealed record BrowserReloadIntent() : AutomationIntent
{
    public override string Kind => "browser.reload";
    public override string Summary => "Reload current browser tab";
}

public enum BrowserHistoryDirection { Back, Forward }

public sealed record BrowserHistoryIntent(BrowserHistoryDirection Direction) : AutomationIntent
{
    public override string Kind => Direction == BrowserHistoryDirection.Back ? "browser.back" : "browser.forward";
    public override string Summary => Direction == BrowserHistoryDirection.Back ? "Browser back" : "Browser forward";
}

public sealed record BrowserFocusInputIntent(string Selector) : AutomationIntent
{
    public override string Kind => "browser.focusInput";
    public override string Summary => $"Focus input '{Selector}'";
}

public sealed record BrowserExtractSelectionIntent() : AutomationIntent
{
    public override string Kind => "browser.extractSelection";
    public override string Summary => "Read current browser selection";
}

public sealed record BrowserScrollIntent(int Dy) : AutomationIntent
{
    public override string Kind => "browser.scroll";
    public override string Summary => $"Scroll browser by {Dy}px";
}

public sealed record BrowserClickSelectorIntent(string Selector) : AutomationIntent
{
    public override string Kind => "browser.click";
    public override string Summary => $"Click '{Selector}' in browser";
}

// ─── File / app ──────────────────────────────────────────────────────────────

public sealed record OpenAppIntent(string Executable, string? Arguments = null) : AutomationIntent
{
    public override string Kind => "app.open";
    public override string Summary => Arguments is null ? $"Launch {Executable}" : $"Launch {Executable} {Arguments}";
}

public sealed record OpenFileIntent(string Path) : AutomationIntent
{
    public override string Kind => "file.open";
    public override string Summary => $"Open {Path}";
}

public sealed record RevealFileIntent(string Path) : AutomationIntent
{
    public override string Kind => "file.reveal";
    public override string Summary => $"Reveal {Path} in Explorer";
}

public sealed record CreateDraftFileIntent(string Path, string Content, bool Overwrite = false) : AutomationIntent
{
    public override string Kind => "file.createDraft";
    public override string Summary => Overwrite
        ? $"Overwrite {Path} with {Content.Length} chars"
        : $"Create draft {Path} ({Content.Length} chars)";
}
