using System.Text.Json;
using FluentAssertions;
using Jarvis.Perception.Browser;
using Xunit;

namespace Jarvis.Perception.Tests;

public class BrowserBridgeProtocolTests
{
    [Fact]
    public void Deserializes_hello()
    {
        var json = """{"type":"hello","browser":"chrome","version":"0.1.0"}""";
        var msg = JsonSerializer.Deserialize<BrowserBridgeMessage>(json)!;
        msg.Type.Should().Be("hello");
        msg.Browser.Should().Be("chrome");
        msg.Version.Should().Be("0.1.0");
    }

    [Fact]
    public void Deserializes_context_with_all_fields()
    {
        var json = """
            {
              "type":"context","browser":"edge","version":"0.1.0",
              "url":"https://x.example/path","domain":"x.example",
              "title":"Foo","selectedText":"hello","focusedElementRole":"textbox",
              "isTextInputFocused":true
            }
            """;
        var msg = JsonSerializer.Deserialize<BrowserBridgeMessage>(json)!;
        msg.Type.Should().Be("context");
        msg.Url.Should().Be("https://x.example/path");
        msg.IsTextInputFocused.Should().Be(true);
        msg.SelectedText.Should().Be("hello");
    }

    [Fact]
    public void Tolerates_unknown_fields()
    {
        var json = """{"type":"context","futureField":42,"url":"https://x"}""";
        var act = () => JsonSerializer.Deserialize<BrowserBridgeMessage>(json);
        act.Should().NotThrow();
    }

    [Fact]
    public void HandleMessage_updates_current_and_raises_updated()
    {
        var provider = new WebSocketBrowserContextProvider(new BridgeTokenStore(Path.Combine(Path.GetTempPath(), "tok-" + Guid.NewGuid().ToString("N"))));
        var fired = 0;
        provider.Updated += (_, _) => fired++;

        provider.HandleMessage("""{"type":"context","browser":"chrome","url":"https://foo.example/","title":"Foo"}""");
        provider.Current.Browser.Should().Be("chrome");
        provider.Current.Url.Should().Be("https://foo.example/");
        provider.Current.Domain.Should().Be("foo.example", because: "domain is derived from the URL when omitted");
        fired.Should().Be(1);

        provider.HandleMessage("""{"type":"hello","browser":"edge"}""");
        provider.Current.Browser.Should().Be("edge");
        fired.Should().Be(2);
    }

    [Fact]
    public void HandleMessage_ignores_bad_json_silently()
    {
        var provider = new WebSocketBrowserContextProvider(new BridgeTokenStore(Path.Combine(Path.GetTempPath(), "tok-" + Guid.NewGuid().ToString("N"))));
        var act = () => provider.HandleMessage("{ not json");
        act.Should().NotThrow();
    }
}
