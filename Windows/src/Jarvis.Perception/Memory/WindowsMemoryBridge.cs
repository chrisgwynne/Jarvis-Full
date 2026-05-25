using System.Text.Json;
using Jarvis.Core.Diagnostics;
using Jarvis.Core.Memory;
using Jarvis.Core.Sidecar;

namespace Jarvis.Perception.Memory;

/// <summary>
/// Handles incoming <c>windows.memory.query</c> frames from the Mac and sends
/// <c>windows.memory.answer</c> responses back through the bridge.
/// </summary>
public sealed class WindowsMemoryBridge : IDisposable
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IMacBridgeCoordinator _bridge;
    private readonly IDesktopMemoryQueryService _memory;
    private readonly IDiagnostics? _diagnostics;
    private bool _attached;

    public WindowsMemoryBridge(
        IMacBridgeCoordinator bridge,
        IDesktopMemoryQueryService memory,
        IDiagnostics? diagnostics = null)
    {
        _bridge = bridge;
        _memory = memory;
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
        if (frame.Type != SidecarFrameTypes.WindowsMemoryQuery) return;

        var routeId = frame.Id ?? Guid.NewGuid().ToString("N");
        var query = frame.MemoryQuery ?? "";

        if (string.IsNullOrWhiteSpace(query))
        {
            await SendAnswer(routeId, "Query is empty.", null).ConfigureAwait(false);
            return;
        }

        _diagnostics?.Record(DiagnosticLevel.Info, "memory.bridge", "query",
            new Dictionary<string, object?> { ["routeId"] = routeId });

        DesktopMemoryAnswer answer;
        try
        {
            answer = await _memory.AnswerAsync(query).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await SendAnswer(routeId, $"Memory query failed: {ex.GetType().Name}", null).ConfigureAwait(false);
            return;
        }

        string? structuredJson = null;
        if (answer.StructuredData is not null)
        {
            try { structuredJson = JsonSerializer.Serialize(answer.StructuredData, JsonOpts); }
            catch { /* skip structured data if not serialisable */ }
        }

        await SendAnswer(routeId, answer.NaturalLanguageAnswer, structuredJson).ConfigureAwait(false);
    }

    private Task<bool> SendAnswer(string routeId, string answer, string? structuredData) =>
        _bridge.SendAsync(new SidecarFrame
        {
            Type = SidecarFrameTypes.WindowsMemoryAnswer,
            Id = routeId,
            MemoryAnswer = answer,
            MemoryData = structuredData,
            At = DateTimeOffset.UtcNow
        });
}
