using Jarvis.Core.Guidance;

namespace Jarvis.Perception.Guidance;

/// <summary>
/// Pure scoring function. Returns a list of (target, score, reason) ordered best-first.
/// Score is in [0, 1] but isn't a probability — it's a relative ranking.
///
/// Components (max contribution shown):
///   label match (0.50) — strongest signal
///   role match  (0.20) — "save" maps to button; "type" to textbox
///   source     (0.10) — BrowserDom > UiAutomation > Ocr > Heuristic
///   cursor     (0.08) — closer to cursor wins ties
///   enabled    (0.07) — disabled targets are not zero-scored, but heavily penalised
///   app match  (0.05) — target's process matches the foreground app
/// </summary>
public static class TargetRanker
{
    private static readonly HashSet<string> Stopwords = new(StringComparer.OrdinalIgnoreCase)
    {
        "where", "do", "i", "to", "the", "a", "an", "this", "that", "click", "press",
        "tap", "button", "for", "on", "of", "in", "at", "is", "would", "should",
        "please", "show", "me", "can", "you", "what"
    };

    /// <summary>
    /// Deterministic synonym table. Keyed by a normalised verb/noun, value is every
    /// equivalent form that should also match a target label.
    /// "submit" → matches Send, Publish, Post, Share.
    /// </summary>
    internal static readonly Dictionary<string, string[]> Synonyms = new(StringComparer.OrdinalIgnoreCase)
    {
        ["submit"]    = new[] { "submit", "send", "publish", "post", "share" },
        ["send"]      = new[] { "send", "submit", "publish", "post", "share" },
        ["publish"]   = new[] { "publish", "submit", "send", "post", "share" },
        ["post"]      = new[] { "post", "publish", "send", "submit", "share" },
        ["share"]     = new[] { "share", "send", "publish", "post" },

        ["continue"]  = new[] { "continue", "next", "proceed", "forward" },
        ["next"]      = new[] { "next", "continue", "proceed", "forward" },
        ["proceed"]   = new[] { "proceed", "continue", "next" },

        ["save"]      = new[] { "save", "store", "keep", "export", "download" },
        ["store"]     = new[] { "store", "save" },
        ["export"]    = new[] { "export", "save", "download" },
        ["download"]  = new[] { "download", "export", "save" },

        ["login"]     = new[] { "login", "log in", "sign in", "signin", "authenticate" },
        ["signin"]    = new[] { "signin", "sign in", "log in", "login", "authenticate" },
        ["authenticate"] = new[] { "authenticate", "log in", "sign in", "login", "signin" },

        ["create"]    = new[] { "create", "new", "add", "make", "start" },
        ["new"]       = new[] { "new", "create", "add", "make", "start" },
        ["add"]       = new[] { "add", "create", "new" },

        ["delete"]    = new[] { "delete", "remove", "trash", "discard", "drop" },
        ["remove"]    = new[] { "remove", "delete", "trash", "discard" },
        ["trash"]     = new[] { "trash", "delete", "remove" },

        ["settings"]  = new[] { "settings", "preferences", "options", "config", "configure" },
        ["preferences"] = new[] { "preferences", "settings", "options", "config" },
        ["options"]   = new[] { "options", "settings", "preferences" },

        ["close"]     = new[] { "close", "dismiss", "exit" },
        ["cancel"]    = new[] { "cancel", "discard", "abort", "no" },
        ["confirm"]   = new[] { "confirm", "ok", "yes", "accept" }
    };

    private static readonly Dictionary<string, string[]> RoleHints = new(StringComparer.OrdinalIgnoreCase)
    {
        ["save"]     = new[] { "button" },
        ["submit"]   = new[] { "button" },
        ["next"]     = new[] { "button" },
        ["continue"] = new[] { "button" },
        ["back"]     = new[] { "button", "hyperlink" },
        ["cancel"]   = new[] { "button" },
        ["create"]   = new[] { "button" },
        ["new"]      = new[] { "button", "menuitem" },
        ["open"]     = new[] { "button", "menuitem" },
        ["close"]    = new[] { "button" },
        ["type"]     = new[] { "textbox", "edit" },
        ["search"]   = new[] { "textbox", "edit" },
        ["link"]     = new[] { "hyperlink" },
        ["tab"]      = new[] { "tabitem" }
    };

    public static IReadOnlyList<RankedCandidate> Rank(string query, IReadOnlyList<UiTarget> candidates,
        int cursorX = 0, int cursorY = 0, string? foregroundProcess = null)
    {
        if (candidates.Count == 0) return Array.Empty<RankedCandidate>();
        var keywords = ExtractKeywords(query);
        var hintedRoles = HintedRoles(keywords);
        var scored = new List<RankedCandidate>(candidates.Count);
        foreach (var t in candidates)
        {
            if (!t.IsValid) continue;
            double score = 0;
            var reasons = new List<string>();

            var labelScore = LabelScore(keywords, t.Label);
            if (labelScore > 0)
            {
                score += 0.50 * labelScore;
                reasons.Add($"label match {labelScore:F2}");
            }

            if (hintedRoles.Count > 0 && hintedRoles.Contains(NormalizeRole(t.Role)))
            {
                score += 0.20;
                reasons.Add($"role={t.Role}");
            }

            score += 0.10 * SourceReliability(t.Source);

            score += 0.08 * CursorProximity(t, cursorX, cursorY);

            if (t.Enabled) score += 0.07; else { score -= 0.05; reasons.Add("disabled"); }

            if (foregroundProcess is not null && t.Process is not null &&
                string.Equals(foregroundProcess, t.Process, StringComparison.OrdinalIgnoreCase))
            {
                score += 0.05;
            }

            // Confidence baseline from the source itself.
            score *= 0.75 + 0.25 * t.Confidence;

            scored.Add(new RankedCandidate(t, Math.Clamp(score, 0, 1), string.Join("; ", reasons)));
        }
        return scored.OrderByDescending(c => c.Score).ToList();
    }

    internal static IReadOnlyList<string> ExtractKeywords(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return Array.Empty<string>();
        var lower = query.ToLowerInvariant();
        return lower.Split(new[] { ' ', '\t', '\n', '?', '!', '.', ',' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w.Length > 1 && !Stopwords.Contains(w))
            .Distinct()
            .ToArray();
    }

    private static HashSet<string> HintedRoles(IReadOnlyList<string> keywords)
    {
        var roles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kw in keywords)
            if (RoleHints.TryGetValue(kw, out var hints))
                foreach (var h in hints) roles.Add(h);
        return roles;
    }

    internal static double LabelScore(IReadOnlyList<string> keywords, string label)
    {
        if (keywords.Count == 0 || string.IsNullOrWhiteSpace(label)) return 0;
        var lower = label.ToLowerInvariant();
        var labelWords = lower.Split(new[] { ' ', '\t', '\n', '-', '_', '/', ':' }, StringSplitOptions.RemoveEmptyEntries);
        double best = 0;
        var hits = 0;
        foreach (var kw in keywords)
        {
            if (lower == kw) return 1.0;

            // Try the keyword and any synonyms.
            var forms = Synonyms.TryGetValue(kw, out var syn) ? syn : new[] { kw };
            var matchedSynonym = false;
            var matchedExact = false;
            foreach (var form in forms)
            {
                if (lower.Contains(form, StringComparison.OrdinalIgnoreCase))
                {
                    matchedSynonym = true;
                    if (labelWords.Any(w => w.Equals(form, StringComparison.OrdinalIgnoreCase)))
                        matchedExact = true;
                    if (matchedExact) break;
                }
            }
            if (!matchedSynonym) continue;
            hits++;
            // Direct keyword (forms[0] == kw) hits beat synonym-only hits.
            var primaryMatch = labelWords.Any(w => w.Equals(kw, StringComparison.OrdinalIgnoreCase))
                || lower.Contains(kw, StringComparison.OrdinalIgnoreCase);
            if (matchedExact && primaryMatch) best = Math.Max(best, 0.9);
            else if (matchedExact)             best = Math.Max(best, 0.78);
            else if (primaryMatch)             best = Math.Max(best, 0.6);
            else                               best = Math.Max(best, 0.55);
        }
        if (hits == 0) return 0;
        return Math.Min(1.0, best + 0.05 * (hits - 1));
    }

    private static double SourceReliability(TargetSource source) => source switch
    {
        TargetSource.BrowserDom => 1.0,
        TargetSource.UiAutomation => 0.75,
        TargetSource.Ocr => 0.4,
        _ => 0.25
    };

    private static double CursorProximity(UiTarget t, int cursorX, int cursorY)
    {
        var (cx, cy) = t.Center;
        var dx = cx - cursorX;
        var dy = cy - cursorY;
        var dist = Math.Sqrt(dx * dx + dy * dy);
        // 500 px ~ "feels nearby"; beyond 2000 px contribution is ~0.
        return Math.Clamp(1.0 - dist / 2000.0, 0, 1);
    }

    private static string NormalizeRole(string role)
    {
        var lower = role.ToLowerInvariant().Trim();
        if (lower.Contains("button")) return "button";
        if (lower.Contains("edit") || lower.Contains("textbox") || lower.Contains("input")) return "textbox";
        if (lower.Contains("menu")) return "menuitem";
        if (lower.Contains("link") || lower.Contains("hyperlink")) return "hyperlink";
        if (lower.Contains("tab")) return "tabitem";
        return lower;
    }
}
