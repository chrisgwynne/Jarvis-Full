using System.Diagnostics;
using System.Text;
using Jarvis.Core.Snapshot;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Returns a list of the top running processes grouped by workflow category.
/// Filters out system/low-priority processes. Returns at most 15 entries.
/// </summary>
public sealed class ProcessInspectTool : IWindowsTool
{
    private static readonly HashSet<string> SystemBlocklist = new(StringComparer.OrdinalIgnoreCase)
    {
        "System", "Registry", "smss", "csrss", "wininit", "lsass", "svchost", "conhost",
        "RuntimeBroker", "services", "winlogon", "dwm", "sihost", "taskhostw", "fontdrvhost",
        "SearchIndexer", "WmiPrvSE", "spoolsv", "LsaIso", "MsMpEng", "NisSrv", "audiodg"
    };

    public string Name => "inspect_processes";
    public IReadOnlyList<string> Aliases { get; } = ["processes", "what_is_running", "running_apps"];
    public string Description => "Lists the top running processes grouped by workflow category.";
    public ToolSafetyLevel SafetyLevel => ToolSafetyLevel.Safe;

    public Task<WindowsToolResult> ExecuteAsync(WindowsToolRequest request, CancellationToken ct = default)
    {
        if (request.DryRun)
        {
            return Task.FromResult(Ok("Would inspect running processes (dry run)", null));
        }

        try
        {
            var processes = Process.GetProcesses()
                .Where(p => !SystemBlocklist.Contains(p.ProcessName))
                .Select(p =>
                {
                    long memMb = 0;
                    try { memMb = p.WorkingSet64 / (1024 * 1024); } catch { }
                    return (Name: p.ProcessName, MemMb: memMb, Category: CategorizeProcess(p.ProcessName));
                })
                .OrderByDescending(p => p.MemMb)
                .Take(15)
                .ToList();

            var grouped = processes
                .GroupBy(p => p.Category)
                .OrderBy(g => g.Key.ToString());

            var sb = new StringBuilder();
            sb.AppendLine("Running processes by category:");
            foreach (var group in grouped)
            {
                sb.AppendLine($"  [{group.Key}]");
                foreach (var p in group.OrderByDescending(x => x.MemMb))
                    sb.AppendLine($"    {p.Name} ({p.MemMb} MB)");
            }

            var summary = $"{processes.Count} processes listed across {grouped.Count()} categories.";
            return Task.FromResult(Ok(summary, sb.ToString().TrimEnd()));
        }
        catch (Exception ex)
        {
            return Task.FromResult(Fail($"Process inspection failed: {ex.Message}"));
        }
    }

    internal static WorkflowCategory CategorizeProcess(string processName)
    {
        // Uses the same process sets as WorkflowCategorizer (accessible from same assembly)
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.IdeProcessNames.Contains(processName))
            return WorkflowCategory.Coding;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.BrowserProcessNames.Contains(processName))
            return WorkflowCategory.Browsing;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.TerminalProcessNames.Contains(processName))
            return WorkflowCategory.TerminalWork;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.CommsProcessNames.Contains(processName))
            return WorkflowCategory.Communication;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.MediaProcessNames.Contains(processName))
            return WorkflowCategory.Media;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.GamingProcessNames.Contains(processName))
            return WorkflowCategory.Gaming;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.EditingProcessNames.Contains(processName))
            return WorkflowCategory.Editing;
        if (Jarvis.Perception.Snapshot.WorkflowCategorizer.WritingProcessNames.Contains(processName))
            return WorkflowCategory.Writing;
        return WorkflowCategory.Unknown;
    }

    private static WindowsToolResult Ok(string summary, string? detail) =>
        new(true, summary, detail, null, ToolPrivacyImpact.AppList, DateTimeOffset.UtcNow);

    private static WindowsToolResult Fail(string summary) =>
        new(false, summary, null, null, ToolPrivacyImpact.AppList, DateTimeOffset.UtcNow);
}
