using System.IO;
using System.Text.Json;
using Jarvis.Core.Conversation;
using Jarvis.Core.Settings;

namespace Jarvis.Perception.Conversation;

/// <summary>
/// Persistent daily request + char counter. Stored at <c>%APPDATA%\Jarvis\quota.json</c>
/// so a process restart doesn't reset the budget. Resets on a new UTC date.
///
/// Local providers (Echo / Ollama) are exempted by default; cloud providers consume from
/// the bucket. The counter is forward-looking — when a reservation puts us over the cap
/// it's rejected; <see cref="RecordOutput"/> reports actual usage but never blocks an
/// in-flight call.
/// </summary>
public sealed class DailyQuotaGuard : IQuotaGuard
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    private readonly string _path;
    private readonly Func<QuotaSettings> _settings;
    private readonly object _gate = new();
    private QuotaCounter _counter;

    public DailyQuotaGuard(Func<QuotaSettings> settings, string? path = null)
    {
        _settings = settings;
        _path = path ?? DefaultPath();
        _counter = Load();
    }

    public static string DefaultPath()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(roaming, "Jarvis", "quota.json");
    }

    public QuotaStatus Status
    {
        get { lock (_gate) { RolloverIfNeeded(); return Snapshot(_counter, _settings()); } }
    }

    public QuotaReservation Reserve(LlmProviderType provider, int approxRequestChars)
    {
        lock (_gate)
        {
            var cfg = _settings();
            if (!cfg.Enabled || (cfg.ExemptLocalProviders && IsLocal(provider)))
                return new QuotaReservation(true, null, Snapshot(_counter, cfg));

            RolloverIfNeeded();

            if (_counter.Requests + 1 > cfg.MaxRequestsPerDay)
                return new QuotaReservation(false, $"daily request cap reached ({cfg.MaxRequestsPerDay})", Snapshot(_counter, cfg));

            if (_counter.Chars + approxRequestChars > cfg.MaxApproxCharsPerDay)
                return new QuotaReservation(false, $"daily char cap reached ({cfg.MaxApproxCharsPerDay:N0})", Snapshot(_counter, cfg));

            _counter = _counter with { Requests = _counter.Requests + 1, Chars = _counter.Chars + approxRequestChars };
            Persist();
            return new QuotaReservation(true, null, Snapshot(_counter, cfg));
        }
    }

    public void RecordOutput(int approxChars)
    {
        if (approxChars <= 0) return;
        lock (_gate)
        {
            var cfg = _settings();
            if (!cfg.Enabled) return;
            RolloverIfNeeded();
            _counter = _counter with { Chars = _counter.Chars + approxChars };
            Persist();
        }
    }

    private void RolloverIfNeeded()
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        if (_counter.Date != today)
            _counter = new QuotaCounter(today, 0, 0);
    }

    private static bool IsLocal(LlmProviderType p) =>
        p is LlmProviderType.None or LlmProviderType.Ollama;

    private static QuotaStatus Snapshot(QuotaCounter c, QuotaSettings cfg)
    {
        var near = c.Requests >= cfg.MaxRequestsPerDay * 0.8 || c.Chars >= cfg.MaxApproxCharsPerDay * 0.8;
        var at = c.Requests >= cfg.MaxRequestsPerDay || c.Chars >= cfg.MaxApproxCharsPerDay;
        return new QuotaStatus(c.Date, c.Requests, c.Chars, cfg.MaxRequestsPerDay, cfg.MaxApproxCharsPerDay, near, at);
    }

    private QuotaCounter Load()
    {
        try
        {
            if (File.Exists(_path))
            {
                var json = File.ReadAllText(_path);
                var c = JsonSerializer.Deserialize<QuotaCounter>(json, JsonOpts);
                if (c is not null && c.Date == DateOnly.FromDateTime(DateTime.UtcNow))
                    return c;
            }
        }
        catch { /* corrupt — fall back to zero */ }
        return new QuotaCounter(DateOnly.FromDateTime(DateTime.UtcNow), 0, 0);
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_counter, JsonOpts));
        }
        catch { /* never let quota I/O propagate */ }
    }

    private sealed record QuotaCounter(DateOnly Date, int Requests, int Chars);
}
