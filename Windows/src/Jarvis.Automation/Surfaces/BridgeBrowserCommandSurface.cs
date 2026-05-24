using System.Text.Json;
using Jarvis.Core.Automation;
using Jarvis.Perception.Browser;

namespace Jarvis.Automation.Surfaces;

/// <summary>
/// Sends host→extension commands over the authenticated bridge.
/// Failure modes: extension not connected; bridge send fails; ack timeout; ack error.
/// </summary>
public sealed class BridgeBrowserCommandSurface : IBrowserCommandSurface
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly WebSocketBrowserContextProvider _bridge;

    public BridgeBrowserCommandSurface(WebSocketBrowserContextProvider bridge) => _bridge = bridge;

    public bool IsAvailable => _bridge.IsConnected;

    public async Task<string?> SendAsync(BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!_bridge.IsConnected) return "no browser extension connected";
        var payload = JsonSerializer.Serialize(command, JsonOpts);
        var ok = await _bridge.SendJsonAsync(payload, cancellationToken).ConfigureAwait(false);
        return ok ? null : "bridge send failed";
    }

    public async Task<BrowserAck> SendWithAckAsync(BrowserCommand command, TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (!_bridge.IsConnected) return BrowserAck.Disconnected(command.CommandId ?? Guid.NewGuid().ToString("N"));
        return await _bridge.SendCommandAsync(command, timeout, cancellationToken).ConfigureAwait(false);
    }
}
