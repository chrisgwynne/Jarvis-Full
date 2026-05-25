using System.Text;
using Jarvis.Core.Awareness;
using Jarvis.Core.Focus;
using Jarvis.Core.Memory;
using Jarvis.Core.Snapshot;

namespace Jarvis.Perception.Memory;

/// <summary>
/// Deterministic, no-LLM memory query service. Matches queries by keyword to handlers
/// that read from <see cref="ISessionMemoryStore"/>, <see cref="IAppUsageTracker"/>,
/// and <see cref="IFocusSessionTracker"/>.
/// </summary>
public sealed class DesktopMemoryQueryService : IDesktopMemoryQueryService
{
    private readonly ISessionMemoryStore _sessionMemory;
    private readonly IAppUsageTracker _appUsage;
    private readonly IFocusSessionTracker _focusTracker;

    public DesktopMemoryQueryService(
        ISessionMemoryStore sessionMemory,
        IAppUsageTracker appUsage,
        IFocusSessionTracker focusTracker)
    {
        _sessionMemory = sessionMemory;
        _appUsage = appUsage;
        _focusTracker = focusTracker;
    }

    public async Task<DesktopMemoryAnswer> AnswerAsync(string query, CancellationToken ct = default)
    {
        var q = query.Trim().ToLowerInvariant();

        if (MatchesCodingTime(q))
            return await AnswerCodingTime(query, ct).ConfigureAwait(false);

        if (MatchesDistractions(q))
            return await AnswerDistractions(query, ct).ConfigureAwait(false);

        if (MatchesBeforeLunch(q))
            return await AnswerBeforeLunch(query, ct).ConfigureAwait(false);

        if (MatchesAfternoon(q))
            return await AnswerAfternoon(query, ct).ConfigureAwait(false);

        if (MatchesTopApps(q))
            return AnswerTopApps(query);

        if (MatchesFocusTime(q))
            return AnswerFocusTime(query);

        if (MatchesProductivity(q))
            return AnswerProductivity(query);

        return AnswerHelp(query);
    }

    // ─── Matchers ────────────────────────────────────────────────────────────────

    private static bool MatchesCodingTime(string q) =>
        q.Contains("cod") || q.Contains("coding time") || q.Contains("how long did i code")
        || q.Contains("programming") || q.Contains("develop");

    private static bool MatchesDistractions(string q) =>
        q.Contains("distract") || q.Contains("what distracted") || q.Contains("distraction");

    private static bool MatchesBeforeLunch(string q) =>
        q.Contains("before lunch") || q.Contains("this morning") || q.Contains("before noon");

    private static bool MatchesAfternoon(string q) =>
        q.Contains("afternoon") || q.Contains("after lunch") || q.Contains("this afternoon");

    private static bool MatchesTopApps(string q) =>
        q.Contains("app") && (q.Contains("most") || q.Contains("used") || q.Contains("top"))
        || q.Contains("what apps");

    private static bool MatchesFocusTime(string q) =>
        q.Contains("focused") || q.Contains("focus time") || q.Contains("how long was i focused")
        || (q.Contains("focus") && q.Contains("how long"));

    private static bool MatchesProductivity(string q) =>
        q.Contains("productivity") || q.Contains("productive score") || q.Contains("how productive");

    // ─── Handlers ────────────────────────────────────────────────────────────────

    private async Task<DesktopMemoryAnswer> AnswerCodingTime(string query, CancellationToken ct)
    {
        var sessions = await _sessionMemory.GetTodayAsync().ConfigureAwait(false);
        var codingSessions = sessions.Where(s => s.PrimaryWorkflow == WorkflowCategory.Coding).ToList();

        var total = codingSessions.Aggregate(TimeSpan.Zero, (acc, s) => acc + s.TotalFocusDuration);

        string answer;
        if (total == TimeSpan.Zero)
        {
            answer = "You haven't had any coding sessions recorded today yet.";
        }
        else
        {
            var h = (int)total.TotalHours;
            var m = total.Minutes;
            answer = h > 0
                ? $"You coded for {h}h {m}m today."
                : $"You coded for {m} minutes today.";
        }

        return new DesktopMemoryAnswer(query, answer,
            new { CodingMinutes = (int)total.TotalMinutes, SessionCount = codingSessions.Count },
            DateTimeOffset.UtcNow);
    }

    private async Task<DesktopMemoryAnswer> AnswerDistractions(string query, CancellationToken ct)
    {
        var entries = _appUsage.GetRecent(50);
        var today = DateTimeOffset.Now.Date;
        var todayEntries = entries.Where(e => e.StartedAt.Date == today).ToList();

        var distractingCategories = new[] { WorkflowCategory.Media, WorkflowCategory.Gaming, WorkflowCategory.Shopping };
        var distractions = todayEntries
            .Where(e => distractingCategories.Contains(e.Workflow))
            .GroupBy(e => e.ProcessName)
            .Select(g => new { App = g.Key, TotalDwell = g.Aggregate(TimeSpan.Zero, (acc, e) => acc + e.Dwell) })
            .OrderByDescending(x => x.TotalDwell)
            .Take(2)
            .ToList();

        string answer;
        if (distractions.Count == 0)
        {
            answer = "No notable distractions detected today.";
        }
        else
        {
            var parts = distractions.Select(d =>
            {
                var m = (int)d.TotalDwell.TotalMinutes;
                return $"{d.App} ({m} min)";
            });
            answer = $"Top distractions today: {string.Join(", ", parts)}.";
        }

        return new DesktopMemoryAnswer(query, answer,
            distractions.Select(d => new { d.App, Minutes = (int)d.TotalDwell.TotalMinutes }).ToList(),
            DateTimeOffset.UtcNow);
    }

    private async Task<DesktopMemoryAnswer> AnswerBeforeLunch(string query, CancellationToken ct)
    {
        var sessions = await _sessionMemory.GetTodayAsync().ConfigureAwait(false);
        var noon = DateTimeOffset.Now.Date.AddHours(12);
        var moringSessions = sessions.Where(s => s.StartedAt < noon).OrderByDescending(s => s.EndedAt).ToList();

        if (moringSessions.Count == 0)
        {
            return new DesktopMemoryAnswer(query, "No sessions recorded this morning.", null, DateTimeOffset.UtcNow);
        }

        var last = moringSessions.First();
        var h = (int)last.TotalFocusDuration.TotalHours;
        var m = last.TotalFocusDuration.Minutes;
        var durationStr = h > 0 ? $"{h}h {m}m" : $"{m}m";
        var answer = $"Before lunch you were mainly working on {last.PrimaryWorkflow} " +
                     $"({last.PrimaryApp ?? "unknown app"}) for {durationStr}.";

        return new DesktopMemoryAnswer(query, answer, last, DateTimeOffset.UtcNow);
    }

    private async Task<DesktopMemoryAnswer> AnswerAfternoon(string query, CancellationToken ct)
    {
        var sessions = await _sessionMemory.GetTodayAsync().ConfigureAwait(false);
        var noon    = DateTimeOffset.Now.Date.AddHours(12);
        var evening = DateTimeOffset.Now.Date.AddHours(17);
        var afternoon = sessions.Where(s => s.StartedAt >= noon && s.StartedAt < evening).ToList();

        if (afternoon.Count == 0)
        {
            return new DesktopMemoryAnswer(query, "No sessions recorded this afternoon yet.", null, DateTimeOffset.UtcNow);
        }

        var grouped = afternoon.GroupBy(s => s.PrimaryWorkflow)
            .OrderByDescending(g => g.Aggregate(TimeSpan.Zero, (acc, s) => acc + s.TotalFocusDuration))
            .ToList();

        var sb = new StringBuilder("This afternoon: ");
        var parts = grouped.Select(g =>
        {
            var total = g.Aggregate(TimeSpan.Zero, (acc, s) => acc + s.TotalFocusDuration);
            var mins = (int)total.TotalMinutes;
            return $"{g.Key} ({mins}m)";
        });
        sb.Append(string.Join(", ", parts));
        sb.Append(".");

        return new DesktopMemoryAnswer(query, sb.ToString(),
            grouped.Select(g => new { Workflow = g.Key.ToString(), Minutes = (int)g.Aggregate(TimeSpan.Zero, (acc, s) => acc + s.TotalFocusDuration).TotalMinutes }).ToList(),
            DateTimeOffset.UtcNow);
    }

    private DesktopMemoryAnswer AnswerTopApps(string query)
    {
        var entries = _appUsage.GetRecent(50);
        var today = DateTimeOffset.Now.Date;
        var todayEntries = entries.Where(e => e.StartedAt.Date == today).ToList();

        if (todayEntries.Count == 0)
        {
            return new DesktopMemoryAnswer(query, "No app usage recorded yet today.", null, DateTimeOffset.UtcNow);
        }

        var top = todayEntries
            .GroupBy(e => e.ProcessName)
            .Select(g => new { App = g.Key, TotalDwell = g.Aggregate(TimeSpan.Zero, (acc, e) => acc + e.Dwell) })
            .OrderByDescending(x => x.TotalDwell)
            .Take(5)
            .ToList();

        var parts = top.Select(a => $"{a.App} ({(int)a.TotalDwell.TotalMinutes}m)");
        var answer = $"Top apps today: {string.Join(", ", parts)}.";

        return new DesktopMemoryAnswer(query, answer,
            top.Select(a => new { a.App, Minutes = (int)a.TotalDwell.TotalMinutes }).ToList(),
            DateTimeOffset.UtcNow);
    }

    private DesktopMemoryAnswer AnswerFocusTime(string query)
    {
        var metrics = _focusTracker.Current;
        var h = (int)metrics.FocusDuration.TotalHours;
        var m = metrics.FocusDuration.Minutes;
        var answer = h > 0
            ? $"You've been focused for {h}h {m}m today."
            : $"You've been focused for {m} minutes today.";

        return new DesktopMemoryAnswer(query, answer,
            new { FocusMinutes = (int)metrics.FocusDuration.TotalMinutes, State = metrics.State.ToString() },
            DateTimeOffset.UtcNow);
    }

    private DesktopMemoryAnswer AnswerProductivity(string query)
    {
        var metrics = _focusTracker.Current;
        var score = (int)(metrics.ProductivityScore * 100);
        var answer = $"Your current productivity score is {score}%.";

        return new DesktopMemoryAnswer(query, answer,
            new { Score = score, State = metrics.State.ToString() },
            DateTimeOffset.UtcNow);
    }

    private static DesktopMemoryAnswer AnswerHelp(string query) =>
        new(query,
            "I can answer questions about your coding time, focus sessions, app usage, and distractions today. " +
            "Try: 'how long did I code today?' or 'what distracted me?' or 'what apps did I use most?' or 'productivity score'.",
            null,
            DateTimeOffset.UtcNow);
}
