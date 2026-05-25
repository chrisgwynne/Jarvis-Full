namespace Jarvis.Core.Tools;

public enum ToolSafetyLevel
{
    Safe,       // read-only, no side effects
    Confirm,    // reversible, brief toast shown
    Approve,    // significant effect, modal approval required
    Blocked     // never executes
}

public sealed record WindowsToolResult(
    bool Success,
    string Summary,         // user-facing short summary
    string? Detail,         // technical detail for diagnostics (no sensitive data)
    string? ArtifactPath,   // e.g. screenshot file path
    ToolPrivacyImpact PrivacyImpact,
    DateTimeOffset At);

public enum ToolPrivacyImpact
{
    None,           // no personal data accessed
    AppList,        // reads running process names
    Clipboard,      // reads clipboard text
    Screenshot,     // captures screen content
    FilePath        // accesses file system paths
}

public sealed record WindowsToolRequest(
    string RouteId,
    string ToolName,
    IReadOnlyDictionary<string, string> Parameters,
    bool DryRun,
    string? RequestedBy,    // "mac" | "dashboard" | "hotkey"
    DateTimeOffset At);

public interface IWindowsTool
{
    string Name { get; }                        // canonical name e.g. "open_app"
    IReadOnlyList<string> Aliases { get; }      // e.g. ["open", "launch", "start"]
    string Description { get; }
    ToolSafetyLevel SafetyLevel { get; }
    Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default);
}
