using Jarvis.Core.Automation;

namespace Jarvis.Core.Guidance;

/// <summary>
/// The natural-language guidance front door: "where do I click to save this?".
/// Returns the best candidate (or null), the runners-up for the inspector, and the
/// click intent the user would invoke if they say "do it".
/// </summary>
public interface IGuidanceService
{
    Task<GuidanceResult> AskAsync(string query, CancellationToken cancellationToken = default);

    /// <summary>Return the most-recent highlighted target, or null. Used by the "click it"
    /// follow-up so callers don't have to re-derive it.</summary>
    UiTarget? LastHighlighted { get; }

    /// <summary>Forget the cached target (e.g. after a successful click or window switch).</summary>
    void Clear();

    /// <summary>Diagnostics for the most recent AskAsync call (or null if none yet).
    /// Powers the inspector's "Last guidance query" panel.</summary>
    GuidanceDiagnostics? LastDiagnostics { get; }
}

public sealed record GuidanceResult(
    string Query,
    UiTarget? Best,
    IReadOnlyList<RankedCandidate> Candidates,
    string Explanation,
    /// <summary>The click intent that would actually fire if the user says "do it".
    /// Null when no acceptable target was found.</summary>
    ClickIntent? SuggestedClick,
    bool LowConfidence)
{
    public bool Found => Best is not null;
}

public sealed record RankedCandidate(UiTarget Target, double Score, string Reason);

/// <summary>Per-query telemetry. Drives the inspector and is recorded once per call.</summary>
public sealed record GuidanceDiagnostics(
    string Query,
    double TotalMs,
    IReadOnlyDictionary<TargetSource, double> SourceLatencyMs,
    IReadOnlyDictionary<TargetSource, int> SourceCandidateCounts,
    string? WinnerLabel,
    TargetSource? WinnerSource,
    double WinnerScore,
    bool LowConfidence,
    bool Cancelled,
    bool Suppressed);
