namespace Jarvis.Core.Automation;

/// <summary>
/// Detects when a target window is owned by an elevated/admin process while Jarvis is not.
/// Such targets silently drop synthesized input (UIPI); without this guard the audit log
/// reports Succeeded for actions that had no effect.
/// </summary>
public interface IElevationProbe
{
    /// <summary>Returns true when the foreground / target window is owned by a process at
    /// a strictly higher integrity level than the current process.</summary>
    bool ForegroundRequiresElevation();

    /// <summary>Same check against a specific hwnd.</summary>
    bool WindowRequiresElevation(IntPtr hwnd);
}
