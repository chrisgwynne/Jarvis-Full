namespace Jarvis.Core.Automation;

public readonly record struct RateLimitDecision(bool Allowed, string? Reason)
{
    public static RateLimitDecision Ok => new(true, null);
    public static RateLimitDecision Deny(string reason) => new(false, reason);
}

/// <summary>
/// Token-bucket-style rate limiter consulted before the approval gate. Implementations
/// must be thread-safe — concurrent callers from different async contexts are expected.
/// </summary>
public interface IRateLimiter
{
    /// <summary>Try to consume one token for this intent kind. Returns <see cref="RateLimitDecision.Deny"/>
    /// when either the per-kind bucket or the global bucket is empty.</summary>
    RateLimitDecision TryAcquire(string intentKind);
}
