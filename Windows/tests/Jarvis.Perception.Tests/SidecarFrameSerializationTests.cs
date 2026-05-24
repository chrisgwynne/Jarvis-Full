using System.Text.Json;
using FluentAssertions;
using Jarvis.Core.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class SidecarFrameSerializationTests
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    [Fact]
    public void Hello_round_trips()
    {
        var f = new SidecarFrame { Type = SidecarFrameTypes.Hello, Protocol = "jarvis-sidecar", Version = "1.0.0", DeviceId = "WORKSTATION" };
        var json = JsonSerializer.Serialize(f, JsonOpts);
        json.Should().Contain("\"type\":\"hello\"");
        json.Should().Contain("WORKSTATION");
        var back = JsonSerializer.Deserialize<SidecarFrame>(json, JsonOpts)!;
        back.Type.Should().Be("hello");
        back.DeviceId.Should().Be("WORKSTATION");
    }

    [Fact]
    public void Transcript_partial_carries_session_and_confidence()
    {
        var f = new SidecarFrame { Type = SidecarFrameTypes.TranscriptPartial, SessionId = "abc", Text = "where do", Confidence = 0.7, IsFinal = false };
        var json = JsonSerializer.Serialize(f, JsonOpts);
        json.Should().Contain("\"isFinal\":false");
        json.Should().NotContain("commandId"); // null fields stripped
    }

    [Fact]
    public void Execute_intent_round_trips_intent_kind_and_json()
    {
        var f = new SidecarFrame { Type = SidecarFrameTypes.ExecuteIntent, CommandId = "c1", IntentKind = "mouse.click", IntentJson = "{\"x\":10,\"y\":20}" };
        var back = JsonSerializer.Deserialize<SidecarFrame>(JsonSerializer.Serialize(f, JsonOpts), JsonOpts)!;
        back.IntentKind.Should().Be("mouse.click");
        back.IntentJson.Should().Contain("\"x\":10");
    }

    [Fact]
    public void Context_payload_round_trips_browser_and_ide_fields()
    {
        var f = new SidecarFrame
        {
            Type = SidecarFrameTypes.Context,
            SnapshotHash = "h1",
            Context = new ContextPayload { ForegroundApp = "Code", IdeEditor = "VS Code", IdeFile = "main.cs", BrowserUrl = "https://x" }
        };
        var json = JsonSerializer.Serialize(f, JsonOpts);
        var back = JsonSerializer.Deserialize<SidecarFrame>(json, JsonOpts)!;
        back.Context!.ForegroundApp.Should().Be("Code");
        back.Context.IdeFile.Should().Be("main.cs");
        back.Context.BrowserUrl.Should().Be("https://x");
    }
}
