using FluentAssertions;
using Jarvis.Core.Conversation;
using Jarvis.Perception.Conversation;
using Xunit;

namespace Jarvis.Perception.Tests;

public class EchoLlmContextSummaryTests
{
    [Fact]
    public void Echo_context_summary_includes_foreground_and_hash()
    {
        var ctx = ConversationContext.Empty with
        {
            ForegroundApp = "Code",
            ForegroundWindowTitle = "main.cs",
            SnapshotHash = "deadbeef"
        };
        var s = EchoLlmClient.ContextSummary(ctx);
        s.Should().Contain("Code");
        s.Should().Contain("main.cs");
        s.Should().Contain("deadbeef");
    }
}
