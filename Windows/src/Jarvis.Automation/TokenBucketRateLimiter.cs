using System.Collections.Concurrent;
using Jarvis.Core.Automation;

namespace Jarvis.Automation;

/// <summary>
/// Per-intent-kind + global token-bucket rate limiter. Buckets refill on every TryAcquire
/// call based on wall clock — no background timer needed.
///
/// Defaults are deliberately tight:
///   - 30 actions/minute global
///   - 8 keystroke-typing actions/minute (catches an LLM stuck in a loop)
///   - 20 clicks/minute
///   - 12 browser-navigations/minute
/// Any unlisted kind falls under the global limit only.
/// </summary>
public sealed class TokenBucketRateLimiter : IRateLimiter
{
    private readonly Bucket _global;
    private readonly ConcurrentDictionary<string, Bucket> _perKind;
    private readonly object _gate = new();

    public TokenBucketRateLimiter(IDictionary<string, (int Capacity, TimeSpan Refill)>? overrides = null,
                                  (int Capacity, TimeSpan Refill)? global = null)
    {
        var g = global ?? (30, TimeSpan.FromMinutes(1));
        _global = new Bucket(g.Capacity, g.Refill);

        var defaults = new Dictionary<string, (int, TimeSpan)>(StringComparer.OrdinalIgnoreCase)
        {
            ["keyboard.type"]   = (8,  TimeSpan.FromMinutes(1)),
            ["keyboard.paste"]  = (8,  TimeSpan.FromMinutes(1)),
            ["mouse.click"]     = (20, TimeSpan.FromMinutes(1)),
            ["mouse.doubleClick"] = (20, TimeSpan.FromMinutes(1)),
            ["browser.navigate"]= (12, TimeSpan.FromMinutes(1)),
            ["browser.click"]   = (12, TimeSpan.FromMinutes(1)),
            ["file.createDraft"]= (6,  TimeSpan.FromMinutes(1)),
            ["app.open"]        = (6,  TimeSpan.FromMinutes(1))
        };
        if (overrides is not null) foreach (var (k, v) in overrides) defaults[k] = v;
        _perKind = new ConcurrentDictionary<string, Bucket>(defaults.Select(kv =>
            new KeyValuePair<string, Bucket>(kv.Key, new Bucket(kv.Value.Item1, kv.Value.Item2))));
    }

    public RateLimitDecision TryAcquire(string intentKind)
    {
        lock (_gate)
        {
            if (_perKind.TryGetValue(intentKind, out var b))
            {
                if (!b.TryConsume())
                    return RateLimitDecision.Deny($"per-kind rate limit ({intentKind}: {b.Capacity}/{b.Window.TotalSeconds:F0}s)");
            }
            if (!_global.TryConsume())
                return RateLimitDecision.Deny($"global rate limit ({_global.Capacity}/{_global.Window.TotalSeconds:F0}s)");
        }
        return RateLimitDecision.Ok;
    }

    private sealed class Bucket
    {
        public readonly int Capacity;
        public readonly TimeSpan Window;
        private double _tokens;
        private DateTimeOffset _lastRefill = DateTimeOffset.UtcNow;
        private readonly double _refillPerSecond;

        public Bucket(int capacity, TimeSpan window)
        {
            Capacity = capacity;
            Window = window;
            _tokens = capacity;
            _refillPerSecond = capacity / window.TotalSeconds;
        }

        public bool TryConsume()
        {
            var now = DateTimeOffset.UtcNow;
            var elapsed = (now - _lastRefill).TotalSeconds;
            if (elapsed > 0)
            {
                _tokens = Math.Min(Capacity, _tokens + elapsed * _refillPerSecond);
                _lastRefill = now;
            }
            if (_tokens < 1) return false;
            _tokens -= 1;
            return true;
        }
    }
}
