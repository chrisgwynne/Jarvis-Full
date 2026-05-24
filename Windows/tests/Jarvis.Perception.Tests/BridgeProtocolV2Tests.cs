using FluentAssertions;
using Jarvis.Core.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class BridgeProtocolV2Tests
{
    [Fact]
    public void Frame_envelope_carries_protocol_version_and_seq_optional()
    {
        var frame = new SidecarFrame
        {
            Type = SidecarFrameTypes.TranscriptPartial,
            ProtocolVersion = SidecarProtocol.Version,
            Seq = 42,
            ReplyTo = "abc"
        };
        var json = System.Text.Json.JsonSerializer.Serialize(frame);
        json.Should().Contain("\"protocolVersion\":2");
        json.Should().Contain("\"seq\":42");
        json.Should().Contain("\"replyTo\":\"abc\"");

        var round = System.Text.Json.JsonSerializer.Deserialize<SidecarFrame>(json)!;
        round.ProtocolVersion.Should().Be(SidecarProtocol.Version);
        round.Seq.Should().Be(42);
        round.ReplyTo.Should().Be("abc");
    }

    [Fact]
    public void Protocol_version_constant_is_2()
    {
        SidecarProtocol.Version.Should().Be(2);
    }
}
