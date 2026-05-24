using System.IO;
using FluentAssertions;
using Jarvis.Core.Settings;
using Jarvis.Perception.Sidecar;
using Xunit;

namespace Jarvis.Perception.Tests;

public class DistributedConversationCoordinatorTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "jarvis-test-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void First_boot_seeds_session_and_device_ids()
    {
        var c = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        c.SessionId.Should().NotBeNullOrEmpty();
        c.DeviceId.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public void Second_boot_resumes_the_same_session_and_device()
    {
        var c1 = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        var s = c1.SessionId; var d = c1.DeviceId;

        var c2 = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        c2.SessionId.Should().Be(s);
        c2.DeviceId.Should().Be(d);
    }

    [Fact]
    public void Rotate_session_changes_id_and_persists()
    {
        var c1 = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        var before = c1.SessionId;
        c1.RotateSession("user cleared history");
        var after = c1.SessionId;
        after.Should().NotBe(before);

        // New instance must see the rotated id, not the original.
        var c2 = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        c2.SessionId.Should().Be(after);
    }

    [Fact]
    public void Rotate_session_fires_event()
    {
        var c = new DistributedConversationCoordinator(() => new SidecarSettings(), _dir);
        var fires = 0;
        c.SessionRotated += (_, _) => fires++;
        c.RotateSession("test");
        fires.Should().Be(1);
    }

    [Fact]
    public void Wake_alias_falls_through_to_settings()
    {
        var c = new DistributedConversationCoordinator(
            () => new SidecarSettings { LocalWakeAlias = "Pebble" }, _dir);
        c.WakeAlias.Should().Be("Pebble");
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}
