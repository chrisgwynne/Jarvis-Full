using System.IO;
using System.Net.WebSockets;
using FluentAssertions;
using Jarvis.Core.Automation;
using Jarvis.Perception.Browser;
using Xunit;

namespace Jarvis.Perception.Tests;

public class BridgeTokenAndAckTests
{
    [Fact]
    public void Token_store_generates_and_persists_token()
    {
        var path = Path.Combine(Path.GetTempPath(), "tok-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new BridgeTokenStore(path);
            var t1 = store.GetOrCreate();
            t1.Should().NotBeNullOrEmpty();
            t1.Length.Should().BeGreaterThanOrEqualTo(32);
            File.Exists(path).Should().BeTrue();
            var store2 = new BridgeTokenStore(path);
            store2.GetOrCreate().Should().Be(t1, "subsequent loads reuse the persisted token");
        }
        finally { try { File.Delete(path); } catch { } }
    }

    [Fact]
    public void ConstantTimeEquals_matches_equal_strings()
    {
        BridgeTokenStore.ConstantTimeEquals("abc", "abc").Should().BeTrue();
        BridgeTokenStore.ConstantTimeEquals("abc", "abd").Should().BeFalse();
        BridgeTokenStore.ConstantTimeEquals("abc", "abcd").Should().BeFalse();
    }

    [Fact]
    public async Task SendCommandAsync_returns_timeout_ack_when_no_extension_connected()
    {
        var tokenPath = Path.Combine(Path.GetTempPath(), "tok-" + Guid.NewGuid().ToString("N"));
        var provider = new WebSocketBrowserContextProvider(new BridgeTokenStore(tokenPath));
        try
        {
            var ack = await provider.SendCommandAsync(new BrowserCommand("navigate", Url: "https://x"), TimeSpan.FromMilliseconds(100));
            ack.Completed.Should().BeFalse();
            ack.Error.Should().NotBeNullOrEmpty();
        }
        finally
        {
            await provider.DisposeAsync();
            try { File.Delete(tokenPath); } catch { }
        }
    }

    [Fact]
    public async Task Rejects_unauthenticated_client()
    {
        var tokenPath = Path.Combine(Path.GetTempPath(), "tok-" + Guid.NewGuid().ToString("N"));
        var provider = new WebSocketBrowserContextProvider(
            new BridgeTokenStore(tokenPath),
            port: FindFreePort());
        provider.Start();
        try
        {
            using var client = new ClientWebSocket();
            // wrong token → server closes with 401
            var url = new Uri($"ws://127.0.0.1:{provider.Port}/?token=wrong");
            Func<Task> connect = () => client.ConnectAsync(url, CancellationToken.None);
            await connect.Should().ThrowAsync<WebSocketException>();
            // Give the server's async auth-rejection handler time to increment the counter
            // before we assert. The WebSocket exception fires as soon as the client receives
            // the close frame, but the server increments AuthRejected a few awaits later.
            await Task.Delay(150);
            provider.AuthRejected.Should().BeGreaterThan(0);
        }
        finally { await provider.DisposeAsync(); try { File.Delete(tokenPath); } catch { } }
    }

    private static int FindFreePort()
    {
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
