using Jarvis.Core.Perception;

namespace Jarvis.Perception.Browser;

/// <summary>
/// Placeholder browser context — always reports "not connected" with an empty snapshot.
/// Replaced by a WebSocket-backed provider once the browser extension lands (P2.5).
/// </summary>
public sealed class StubBrowserContext : IBrowserContext
{
    public BrowserContextSnapshot Current { get; } = BrowserContextSnapshot.Empty;
    public bool IsConnected => false;
    public event EventHandler<BrowserContextSnapshot>? Updated { add { } remove { } }
}
