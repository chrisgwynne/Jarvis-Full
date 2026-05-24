using Jarvis.Core.Settings;

namespace Jarvis.Core.Conversation;

public sealed record QuotaStatus(
    DateOnly Date,
    int RequestsToday,
    int CharsToday,
    int MaxRequestsPerDay,
    int MaxApproxCharsPerDay,
    bool NearLimit,
    bool AtLimit);

public sealed record QuotaReservation(bool Allowed, string? Reason, QuotaStatus After);

public interface IQuotaGuard
{
    QuotaStatus Status { get; }

    /// <summary>Try to reserve one request + an approximate output budget. Returns
    /// Allowed=false with a reason when over limit. Local providers (Echo / Ollama)
    /// are exempted by default — see <see cref="QuotaSettings.ExemptLocalProviders"/>.</summary>
    QuotaReservation Reserve(LlmProviderType provider, int approxRequestChars);

    /// <summary>Record actual output chars (best-effort). May push the day over limit
    /// without rejecting the in-flight call (the cap is forward-looking).</summary>
    void RecordOutput(int approxChars);
}
