namespace Jarvis.Core.State;

public readonly record struct PebbleStateTransition(
    PebbleState From,
    PebbleState To,
    DateTimeOffset At,
    string Reason,
    /// <summary>Elapsed time in the previous state. Zero on first transition.</summary>
    TimeSpan DwellTime = default);
