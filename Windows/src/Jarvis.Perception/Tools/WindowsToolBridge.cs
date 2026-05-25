using Jarvis.Core.Diagnostics;
using Jarvis.Core.Sidecar;
using Jarvis.Core.Tools;

namespace Jarvis.Perception.Tools;

/// <summary>
/// Handles incoming <c>windows.tool.request</c> frames from the Mac and sends
/// <c>windows.tool.result</c> responses back through the bridge.
///
/// Security: only named tools in the registry are invoked. Unknown tool names
/// return a failure result. Stale requests (older than 60 seconds) are silently dropped.
/// Each tool execution has a 30-second timeout.
/// </summary>
public sealed class WindowsToolBridge : IDisposable
{
    private static readonly TimeSpan ExecutionTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan StaleThreshold = TimeSpan.FromSeconds(60);

    private readonly IMacBridgeCoordinator _bridge;
    private readonly IWindowsToolRegistry _registry;
    private readonly IDiagnostics? _diagnostics;
    private bool _attached;

    public WindowsToolBridge(
        IMacBridgeCoordinator bridge,
        IWindowsToolRegistry registry,
        IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _registry = registry;
        _diagnostics = diagnostics;
    }

    public void Attach()
    {
        if (_attached) return;
        _attached = true;
        _bridge.FrameReceived += OnFrame;
    }

    public void Dispose()
    {
        if (_attached) _bridge.FrameReceived -= OnFrame;
        _attached = false;
    }

    private async void OnFrame(object? sender, SidecarFrame frame)
    {
        if (frame.Type != SidecarFrameTypes.WindowsToolRequest) return;

        // Stale request guard
        if (frame.At.HasValue && DateTimeOffset.UtcNow - frame.At.Value > StaleThreshold)
        {
            _diagnostics?.Record(DiagnosticLevel.Warn, "tool.bridge", "stale request dropped",
                new Dictionary<string, object?> { ["tool"] = frame.ToolName, ["age_ms"] = (DateTimeOffset.UtcNow - frame.At.Value).TotalMilliseconds });
            return;
        }

        var routeId = frame.Id ?? Guid.NewGuid().ToString("N");
        var toolName = frame.ToolName ?? "";

        var tool = _registry.Find(toolName);
        if (tool is null)
        {
            await SendResult(routeId, false, $"Unknown tool '{toolName}'.", null, null, null).ConfigureAwait(false);
            return;
        }

        var toolRequest = new WindowsToolRequest(
            RouteId: routeId,
            ToolName: toolName,
            Parameters: frame.ToolParameters ?? new Dictionary<string, string>(),
            DryRun: frame.DryRun ?? false,
            RequestedBy: "mac",
            At: frame.At ?? DateTimeOffset.UtcNow);

        _diagnostics?.Record(DiagnosticLevel.Info, "tool.bridge", "tool.request",
            new Dictionary<string, object?> { ["tool"] = toolName, ["routeId"] = routeId, ["dryRun"] = toolRequest.DryRun });

        using var cts = new CancellationTokenSource(ExecutionTimeout);
        WindowsToolResult result;
        try
        {
            result = await tool.ExecuteAsync(toolRequest, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            result = new WindowsToolResult(false, $"Tool '{toolName}' timed out after 30 seconds.",
                null, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
        }
        catch (Exception ex)
        {
            result = new WindowsToolResult(false, $"Tool '{toolName}' threw an exception.",
                ex.GetType().Name, null, ToolPrivacyImpact.None, DateTimeOffset.UtcNow);
        }

        _diagnostics?.Record(
            result.Success ? DiagnosticLevel.Info : DiagnosticLevel.Warn,
            "tool.bridge", "tool.result",
            new Dictionary<string, object?> { ["tool"] = toolName, ["success"] = result.Success, ["routeId"] = routeId });

        await SendResult(routeId, result.Success, result.Summary, result.Detail,
            result.ArtifactPath, result.PrivacyImpact.ToString()).ConfigureAwait(false);
    }

    private Task<bool> SendResult(string routeId, bool success, string summary, string? detail,
        string? artifactPath, string? privacyImpact) =>
        _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.WindowsToolResult,
            Id = routeId,
            ToolSuccess = success,
            ToolSummary = summary,
            ToolDetail = detail,
            ArtifactPath = artifactPath,
            PrivacyImpact = privacyImpact,
            At = DateTimeOffset.UtcNow
        });
}
