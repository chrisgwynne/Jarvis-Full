namespace Jarvis.Core.Presence;

/// <summary>
/// Exponential moving average over an audio-amplitude stream. Designed for driving the
/// Pebble's waveform / "speaking energy" visualisation — never for actual audio analysis.
///
/// Properties:
///   - Asymmetric: attack is fast (responsive to onsets), decay is slow (smooth tail).
///   - Clamps to [0, 1] so the renderer can map directly to opacity / scale.
///   - Outputs three quantised buckets (Low/Mid/High) so the CSS class can be set
///     without forcing a layout pass each frame — flip the bucket, not the variable.
/// </summary>
public sealed class AmplitudeSmoother
{
    public enum Bucket { Low, Mid, High }

    private readonly double _attack;
    private readonly double _decay;
    private double _value;

    public double Value => _value;
    public Bucket Current => Quantise(_value);

    /// <param name="attack">0..1 — fraction of the gap closed each tick on the way up.</param>
    /// <param name="decay">0..1 — fraction of the gap closed each tick on the way down.</param>
    public AmplitudeSmoother(double attack = 0.45, double decay = 0.08)
    {
        _attack = Math.Clamp(attack, 0.01, 1.0);
        _decay = Math.Clamp(decay, 0.01, 1.0);
    }

    /// <summary>Feed a new sample (0..1). Returns the smoothed value.</summary>
    public double Push(double sample)
    {
        sample = Math.Clamp(sample, 0.0, 1.0);
        var rate = sample > _value ? _attack : _decay;
        _value += (sample - _value) * rate;
        if (_value < 0.001) _value = 0; // snap to floor so CSS doesn't paint silent pulses
        return _value;
    }

    public void Reset() { _value = 0; }

    private static Bucket Quantise(double v)
        => v < 0.2 ? Bucket.Low : v < 0.6 ? Bucket.Mid : Bucket.High;
}
