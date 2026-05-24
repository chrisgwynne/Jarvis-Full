using FluentAssertions;
using Jarvis.Core.Input;
using Xunit;

namespace Jarvis.Core.Tests;

public class MouseChordDetectorTests
{
    private static MouseChordDetector Make(int threshold = 250) => new() { ThresholdMs = threshold };

    [Fact]
    public void Left_then_right_within_threshold_opens()
    {
        var d = Make();
        var fires = 0;
        d.ChordDetected += (_, _) => fires++;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t).Should().BeFalse();
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(100)).Should().BeTrue();
        fires.Should().Be(1);
    }

    [Fact]
    public void Right_then_left_within_threshold_also_opens()
    {
        var d = Make();
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Right, t).Should().BeFalse();
        d.OnButtonDown(MouseButton.Left, t.AddMilliseconds(150)).Should().BeTrue();
    }

    [Fact]
    public void Outside_threshold_does_not_open()
    {
        var d = Make(threshold: 200);
        var ignored = new List<ChordIgnoreReason>();
        d.ChordIgnored += (_, r) => ignored.Add(r);

        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(400)).Should().BeFalse();
        ignored.Should().Contain(ChordIgnoreReason.OutsideThreshold);
    }

    [Fact]
    public void Only_left_does_not_open()
    {
        var d = Make();
        d.OnButtonDown(MouseButton.Left, DateTimeOffset.UtcNow).Should().BeFalse();
        d.BothDown.Should().BeFalse();
    }

    [Fact]
    public void Only_right_does_not_open()
    {
        var d = Make();
        d.OnButtonDown(MouseButton.Right, DateTimeOffset.UtcNow).Should().BeFalse();
    }

    [Fact]
    public void Holding_both_does_not_re_fire()
    {
        var d = Make();
        var fires = 0;
        d.ChordDetected += (_, _) => fires++;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(50));
        // Both held — further events are ignored even if either toggles spuriously.
        d.OnButtonDown(MouseButton.Left, t.AddMilliseconds(100));
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(150));
        fires.Should().Be(1);
    }

    [Fact]
    public void Release_resets_so_next_gesture_fires_again()
    {
        var d = Make();
        var fires = 0;
        d.ChordDetected += (_, _) => fires++;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(60));
        d.OnButtonUp(MouseButton.Left);
        d.OnButtonUp(MouseButton.Right);

        d.OnButtonDown(MouseButton.Left, t.AddSeconds(1));
        d.OnButtonDown(MouseButton.Right, t.AddSeconds(1).AddMilliseconds(50));
        fires.Should().Be(2);
    }

    [Fact]
    public void Releasing_one_button_only_does_not_re_arm()
    {
        var d = Make();
        var fires = 0;
        d.ChordDetected += (_, _) => fires++;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(50));
        d.OnButtonUp(MouseButton.Left);
        // Right still held; pressing left again must not re-fire.
        d.OnButtonDown(MouseButton.Left, t.AddMilliseconds(200));
        fires.Should().Be(1);
    }

    [Fact]
    public void Disabled_detector_ignores_chord()
    {
        var d = Make();
        d.Enabled = false;
        var fires = 0;
        d.ChordDetected += (_, _) => fires++;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(50));
        fires.Should().Be(0);
    }

    [Fact]
    public void Chord_event_carries_actual_delta()
    {
        var d = Make();
        ChordEvent? captured = null;
        d.ChordDetected += (_, e) => captured = e;
        var t = DateTimeOffset.UtcNow;
        d.OnButtonDown(MouseButton.Left, t);
        d.OnButtonDown(MouseButton.Right, t.AddMilliseconds(120));
        captured.Should().NotBeNull();
        captured!.Value.Delta.TotalMilliseconds.Should().BeApproximately(120, 0.001);
    }
}
