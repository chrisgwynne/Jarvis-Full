using FluentAssertions;
using Jarvis.Core.Presence;
using Xunit;

namespace Jarvis.Core.Tests;

public class AmplitudeSmootherTests
{
    [Fact]
    public void Resets_to_zero()
    {
        var s = new AmplitudeSmoother();
        s.Push(0.9); s.Push(0.9); s.Push(0.9);
        s.Reset();
        s.Value.Should().Be(0);
    }

    [Fact]
    public void Attack_faster_than_decay()
    {
        var s = new AmplitudeSmoother(attack: 0.5, decay: 0.1);
        // Single 1.0 sample — value jumps halfway up due to attack=0.5.
        s.Push(1.0).Should().BeApproximately(0.5, 0.001);
        // Single 0 sample after — value drops only 10% due to decay=0.1.
        s.Push(0.0).Should().BeApproximately(0.45, 0.01);
    }

    [Fact]
    public void Clamps_to_unit_range()
    {
        var s = new AmplitudeSmoother();
        s.Push(2.0); // out-of-range high
        s.Value.Should().BeLessThanOrEqualTo(1.0);
        s.Push(-1.0); // out-of-range low
        s.Value.Should().BeGreaterThanOrEqualTo(0.0);
    }

    [Fact]
    public void Buckets_partition_the_range_correctly()
    {
        var s = new AmplitudeSmoother(attack: 1.0, decay: 1.0); // disable smoothing for the test
        s.Push(0.1); s.Current.Should().Be(AmplitudeSmoother.Bucket.Low);
        s.Push(0.4); s.Current.Should().Be(AmplitudeSmoother.Bucket.Mid);
        s.Push(0.8); s.Current.Should().Be(AmplitudeSmoother.Bucket.High);
    }

    [Fact]
    public void Snaps_floor_to_zero_to_avoid_silent_pulses()
    {
        var s = new AmplitudeSmoother(attack: 0.5, decay: 0.5);
        for (var i = 0; i < 30; i++) s.Push(0); // walk down past the snap threshold
        s.Value.Should().Be(0);
    }
}
