using Jarvis.Core.Automation;

namespace Jarvis.Automation;

/// <summary>
/// Generates an <see cref="AutomationPlan"/> from an intent without performing any I/O.
/// Pure function of (intent, policy). Used to populate the approval prompt and as the
/// authoritative description in the audit log.
/// </summary>
public sealed class DryRunPlanner : IDryRunPlanner
{
    private readonly IApprovalPolicy _policy;
    public DryRunPlanner(IApprovalPolicy policy) => _policy = policy;

    public AutomationPlan Plan(AutomationIntent intent)
    {
        var safety = _policy.Classify(intent);
        var (steps, target, undo) = Describe(intent);
        return new AutomationPlan(
            Headline: intent.Summary,
            Steps: steps,
            Target: target,
            UndoHint: undo,
            Safety: safety);
    }

    internal static (IReadOnlyList<string> Steps, string? Target, string? UndoHint) Describe(AutomationIntent intent) => intent switch
    {
        FocusWindowIntent f => (
            new[] { $"Locate window of process '{f.Process}'", "Call SetForegroundWindow on its hwnd" },
            $"process={f.Process}",
            "Alt-Tab back to the previous window"),

        MoveWindowIntent m => (
            new[] { $"SetWindowPos hwnd={m.Hwnd} → ({m.X},{m.Y})" },
            $"hwnd={m.Hwnd}",
            "Drag the window back, or call MoveWindow with the original rect"),

        ResizeWindowIntent r => (
            new[] { $"SetWindowPos hwnd={r.Hwnd} size=({r.Width}×{r.Height})" },
            $"hwnd={r.Hwnd}",
            "Resize back manually"),

        SetWindowStateIntent s => (
            new[] { $"ShowWindow {s.State} on hwnd={s.Hwnd}" },
            $"hwnd={s.Hwnd}",
            s.State switch
            {
                WindowState.Minimized => "Restore from taskbar",
                WindowState.Maximized => "Restore by double-clicking the title bar",
                _ => "Re-toggle the state"
            }),

        SwitchAppIntent sw => (
            new[] { $"Find a top-level window for '{sw.Process}'", "Focus it" },
            $"process={sw.Process}",
            "Alt-Tab back"),

        SendShortcutIntent sh => (
            new[] { $"SendInput key chord: {sh.Accelerator}" },
            "foreground window",
            "Press the inverse shortcut, or Ctrl+Z if the action mutated content"),

        TypeTextIntent t => (
            new[] { $"SendInput Unicode keystrokes for: {TypeTextIntent.Preview(t.Text)}" },
            "foreground window",
            "Press Ctrl+Z in the target app (one undo per word in most editors)"),

        PasteTextIntent p => (
            new[] {
                "Save existing clipboard contents",
                $"Place {TypeTextIntent.Preview(p.Text)} on the clipboard",
                "SendInput Ctrl+V",
                "Restore prior clipboard"
            },
            "foreground window",
            "Press Ctrl+Z in the target app"),

        PressKeyIntent pk => (
            new[] { $"SendInput key: {pk.Key}" },
            "foreground window",
            null),

        MoveCursorIntent mc => (
            new[] { $"SetCursorPos ({mc.X},{mc.Y})" },
            null,
            "Move the cursor manually"),

        ClickIntent ck => (
            new[] {
                $"SetCursorPos ({ck.X},{ck.Y})",
                $"SendInput mouse {ck.Button} ×{ck.Count}"
            },
            $"screen=({ck.X},{ck.Y})",
            "Press Ctrl+Z if the click mutated content; otherwise click elsewhere"),

        ScrollIntent sc => (
            new[] { $"SendInput mouse wheel ({sc.Dx},{sc.Dy})" },
            "foreground window",
            "Scroll back manually"),

        HighlightTargetIntent hi => (
            new[] { $"Draw overlay rect {hi.Width}×{hi.Height} at ({hi.X},{hi.Y})" },
            hi.Label,
            "Highlight fades automatically"),

        BrowserNavigateIntent bn => (
            new[] { "Send {type: 'navigate'} to the browser extension" },
            bn.Url,
            "Press the Back button in the browser"),

        BrowserReloadIntent => (
            new[] { "Send {type: 'reload'} to the extension" },
            "active tab",
            "Browsers reload from cache by default; no undo"),

        BrowserHistoryIntent bh => (
            new[] { $"Send {{type: '{(bh.Direction == BrowserHistoryDirection.Back ? "back" : "forward")}'}} to the extension" },
            "active tab",
            bh.Direction == BrowserHistoryDirection.Back ? "Press Forward" : "Press Back"),

        BrowserFocusInputIntent bf => (
            new[] { $"Send {{type: 'focusInput', selector: '{bf.Selector}'}}" },
            bf.Selector,
            "Click elsewhere to blur the input"),

        BrowserExtractSelectionIntent => (
            new[] { "Send {type: 'extractSelection'} to the extension; the next 'context' frame includes the selection" },
            "active tab",
            null),

        BrowserScrollIntent bsc => (
            new[] { $"Send {{type: 'scroll', dy: {bsc.Dy}}} to the extension" },
            "active tab",
            "Scroll back manually"),

        BrowserClickSelectorIntent bc => (
            new[] { $"Send {{type: 'click', selector: '{bc.Selector}'}}" },
            bc.Selector,
            "Press Browser Back if the click navigated; otherwise no automatic undo"),

        OpenAppIntent oa => (
            new[] { $"Process.Start('{oa.Executable}'{(oa.Arguments is null ? "" : $", '{oa.Arguments}'")})" },
            oa.Executable,
            "Close the app via Alt+F4 or its window controls"),

        OpenFileIntent of => (
            new[] { $"Process.Start with UseShellExecute on '{of.Path}'" },
            of.Path,
            "Close the opened app/window"),

        RevealFileIntent rf => (
            new[] { $"explorer.exe /select,\"{rf.Path}\"" },
            rf.Path,
            null),

        CreateDraftFileIntent cd => (
            new[] {
                $"Ensure directory: {System.IO.Path.GetDirectoryName(cd.Path)}",
                cd.Overwrite ? $"Overwrite {cd.Path}" : $"Write new file at {cd.Path}",
                $"{cd.Content.Length} characters"
            },
            cd.Path,
            $"Delete the file at {cd.Path}"),

        _ => (new[] { "(no description)" }, null, null)
    };
}
