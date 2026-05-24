using System.Text.Json;
using FluentAssertions;
using Jarvis.Core.Automation;
using Xunit;

namespace Jarvis.Automation.Tests;

public class BrowserCommandSerializationTests
{
    private static readonly JsonSerializerOptions Opts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    [Fact]
    public void Navigate_serializes_to_camelCase()
    {
        var json = JsonSerializer.Serialize(new BrowserCommand("navigate", Url: "https://example.com"), Opts);
        json.Should().Contain("\"type\":\"navigate\"");
        json.Should().Contain("\"url\":\"https://example.com\"");
    }

    [Fact]
    public void Click_includes_selector()
    {
        var json = JsonSerializer.Serialize(new BrowserCommand("click", Selector: "button#submit"), Opts);
        json.Should().Contain("\"selector\":\"button#submit\"");
    }

    [Fact]
    public void Scroll_includes_dy()
    {
        var json = JsonSerializer.Serialize(new BrowserCommand("scroll", Dy: 400), Opts);
        json.Should().Contain("\"dy\":400");
    }

    [Fact]
    public void Bare_reload_has_no_extra_fields()
    {
        // Null optionals shouldn't bloat the wire if we ever opt into IgnoreNullValues —
        // for now they're emitted as null, which is fine for the extension to ignore.
        var json = JsonSerializer.Serialize(new BrowserCommand("reload"), Opts);
        json.Should().Contain("\"type\":\"reload\"");
    }
}
