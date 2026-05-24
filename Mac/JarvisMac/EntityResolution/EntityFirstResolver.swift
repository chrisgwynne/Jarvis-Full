import Foundation
import os

// MARK: - EntityFirstResolver

/// The universal entity-first resolution layer. Runs before phrase matching so
/// specific named entities outrank generic category intents.
///
/// Pipeline position (inside handleTranscript):
///   Step 0: follow-up resolution
///   Step 2.5: ConversationRouter
///   Step 2.7: EntityFirstResolver  ← this class
///   Step 3a: phrase-store matching
///   Step 4:  IntentRouter
///   Step 5:  LLM fallback
@MainActor
final class EntityFirstResolver {

    static let shared = EntityFirstResolver()

    // MARK: - Config

    /// Minimum score to accept an entity resolution and bypass generic intent.
    static let minimumConfidence: Double = 0.72
    /// When two top candidates are within this margin, surface a clarification.
    static let clarificationMargin: Double = 0.10

    // MARK: - Providers (registered at bootstrap)

    private(set) var providers: [EntityProvider] = []

    private let log = Logger(subsystem: "Jarvis", category: "entity_resolver")

    // MARK: - Registration

    func register(_ provider: EntityProvider) {
        providers.append(provider)
    }

    func registerDefaults(
        haAliasStore: HomeEntityAliasStore?,
        haEntityRegistry: HAEntityRegistry?,
        getGitHubNotifications: (() -> [GHNotification])? = nil
    ) {
        providers = [
            MediaEntityProvider(),
            AppEntityProvider(),
            BrowserEntityProvider(),
            MemoryEntityProvider(),
            ContactEntityProvider(),
            FileEntityProvider(),
            NoteEntityProvider(),
            CustomEntityAliasProvider.shared,
        ]
        if let store = haAliasStore {
            providers.append(HomeAssistantEntityProvider(aliasStore: store, registry: haEntityRegistry))
        }
        if let reg = haEntityRegistry {
            providers.append(HAAreaEntityProvider(registry: reg))
        }
        if let ghClosure = getGitHubNotifications {
            providers.append(GitHubEntityProvider(getNotifications: ghClosure))
        }
    }

    // MARK: - Resolution

    /// Entry point. Returns nil if no entity meets the confidence threshold.
    func resolve(transcript normalized: String, rawText: String) async -> EntityResolutionResult? {
        let (action, spans) = NounSpanExtractor.extract(from: normalized)

        guard !spans.isEmpty else { return nil }

        // Gather all candidates from all providers in parallel
        var allCandidates: [EntityCandidate] = []
        await withTaskGroup(of: [EntityCandidate].self) { group in
            for provider in providers {
                group.addTask {
                    await provider.candidates(for: spans)
                }
            }
            for await batch in group {
                allCandidates.append(contentsOf: batch)
            }
        }

        guard !allCandidates.isEmpty else { return nil }

        // Score each candidate against each span, keep best score per candidate
        var scored = allCandidates.map { candidate -> EntityCandidate in
            var best = candidate
            best.score = 0
            for span in spans {
                let (s, reason) = EntityScorer.score(span: span, against: candidate)
                if s > best.score {
                    best.score = s
                    best.matchReason = reason
                }
            }
            return best
        }

        // Sort descending by score
        scored.sort { $0.score > $1.score }

        guard let top = scored.first, top.score >= Self.minimumConfidence else {
            log.debug("entity_resolver: no candidate cleared threshold \(Self.minimumConfidence, format: .fixed(precision: 2)) for spans=\(spans)")
            return nil
        }

        // Clarification: two candidates close together
        let second = scored.dropFirst().first
        let needsClarification: Bool = {
            guard let s2 = second, s2.score >= Self.minimumConfidence else { return false }
            return (top.score - s2.score) < Self.clarificationMargin
                && top.entityType != s2.entityType
        }()

        // Pick the best-matching span name for the top candidate
        var bestSpan = spans[0]
        var bestSpanScore = 0.0
        for span in spans {
            let (s, _) = EntityScorer.score(span: span, against: top)
            if s > bestSpanScore { bestSpanScore = s; bestSpan = span }
        }

        log.info("entity_resolver: resolved \"\(bestSpan)\" → \(top.displayName) [\(top.entityType.rawValue)] score=\(String(format:"%.2f",top.score)) reason=\(top.matchReason) action=\(action.rawValue) clarify=\(needsClarification) provider=\(top.provider)")

        if let second {
            log.debug("entity_resolver: runner-up \(second.displayName) score=\(String(format:"%.2f",second.score))")
        }

        let result = EntityResolutionResult(
            originalSpan: bestSpan,
            action: action,
            entity: top,
            competingCandidates: Array(scored.dropFirst().prefix(3)),
            needsClarification: needsClarification
        )
        EntityResolutionDiagnostics.shared.record(result)
        return result
    }
}

// MARK: - NounSpanExtractor

/// Strips action verbs and articles from a transcript, leaving the entity span(s).
enum NounSpanExtractor {

    private static let compoundVerbs: [(String, EntityAction)] = [
        ("turn on the",  .control), ("turn on",    .control),
        ("turn off the", .control), ("turn off",   .control),
        ("switch on",    .control), ("switch off",  .control),
        ("open up",      .open),    ("go to",       .navigate),
        ("navigate to",  .navigate),("browse to",   .navigate),
        ("look up",      .search),  ("search for",  .search),
        ("find me",      .find),    ("find the",    .find),
        ("play me",      .play),    ("put on",      .play),
        ("pull up",      .open),    ("launch the",  .open),
        ("check my",     .show),    ("show me",     .show),
    ]

    private static let singleVerbs: [(String, EntityAction)] = [
        ("open",    .open),
        ("launch",  .open),
        ("start",   .open),
        ("play",    .play),
        ("stream",  .play),
        ("show",    .show),
        ("display", .show),
        ("find",    .find),
        ("search",  .search),
        ("navigate",.navigate),
        ("browse",  .navigate),
        ("visit",   .navigate),
        ("message", .send),
        ("text",    .send),
        ("call",    .call),
        ("email",   .send),
        ("send",    .send),
        ("create",  .create),
        ("make",    .create),
        ("check",   .show),
        ("load",    .open),
    ]

    private static let articles: Set<String> = ["the", "a", "an", "my"]

    static func extract(from normalized: String) -> (EntityAction, [String]) {
        var s = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        var action = EntityAction.unknown

        // Try compound verbs first (longest match wins)
        for (verb, act) in compoundVerbs {
            if s.hasPrefix(verb + " ") || s == verb {
                s = String(s.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                action = act
                break
            }
        }

        // Try single verb if no compound matched
        if action == .unknown {
            let words = s.components(separatedBy: " ")
            if let first = words.first,
               let match = singleVerbs.first(where: { $0.0 == first }) {
                action = match.1
                s = words.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }
        }

        // Strip leading articles
        let words = s.components(separatedBy: " ").filter { !$0.isEmpty }
        var stripped = words
        while let first = stripped.first, articles.contains(first) {
            stripped = Array(stripped.dropFirst())
        }
        s = stripped.joined(separator: " ")

        guard !s.isEmpty else { return (action, []) }

        // Generate spans: full phrase + each individual word
        var spans: [String] = [s]
        let parts = s.components(separatedBy: " ").filter { !$0.isEmpty && $0.count > 2 }
        spans += parts
        // Also try without trailing "news"/"channel"/"tv" qualifiers
        if let last = parts.last, ["news", "channel", "tv", "radio", "fm", "am"].contains(last) {
            let withoutLast = parts.dropLast().joined(separator: " ")
            if !withoutLast.isEmpty { spans.append(withoutLast) }
        }

        return (action, spans)
    }
}

// MARK: - EntityScorer

/// Scores a span string against a single EntityCandidate.
/// Returns (score 0–1, reason label).
enum EntityScorer {

    static func score(span: String, against candidate: EntityCandidate) -> (Double, String) {
        let lower = span.lowercased()
        let name  = candidate.displayName.lowercased()

        // 1. Exact display name
        if lower == name { return (1.00, "exact") }

        // 2. Exact alias
        for alias in candidate.aliases {
            let a = alias.lowercased()
            if lower == a { return (0.97, "alias:\(alias)") }
        }

        // 3. Display name starts with span (or vice versa)
        if name.hasPrefix(lower) || lower.hasPrefix(name) {
            let ratio = Double(min(lower.count, name.count)) / Double(max(lower.count, name.count))
            return (0.75 + ratio * 0.15, "prefix")
        }

        // 4. Any alias starts with span
        for alias in candidate.aliases {
            let a = alias.lowercased()
            if a.hasPrefix(lower) || lower.hasPrefix(a) {
                let ratio = Double(min(lower.count, a.count)) / Double(max(lower.count, a.count))
                let sc = 0.70 + ratio * 0.15
                if sc >= 0.70 { return (sc, "alias_prefix:\(alias)") }
            }
        }

        // 5. Name contains span (e.g. "sports" in "Sky Sports")
        if name.contains(lower) {
            let ratio = Double(lower.count) / Double(name.count)
            return (0.55 + ratio * 0.20, "contains")
        }

        // 6. Fuzzy — Jaro-Winkler against name and all aliases
        var bestFuzzy = jaroWinkler(lower, name)
        var bestAlias = ""
        for alias in candidate.aliases {
            let jw = jaroWinkler(lower, alias.lowercased())
            if jw > bestFuzzy { bestFuzzy = jw; bestAlias = alias }
        }
        if bestFuzzy >= 0.82 {
            let reason = bestAlias.isEmpty ? "fuzzy" : "fuzzy_alias:\(bestAlias)"
            return (bestFuzzy * 0.88, reason)
        }

        // 7. Phonetic — Soundex
        let spanCode = soundex(lower)
        let nameCode = soundex(name)
        if spanCode == nameCode && spanCode != "0000" {
            return (0.72, "phonetic")
        }
        for alias in candidate.aliases {
            if soundex(alias.lowercased()) == spanCode && spanCode != "0000" {
                return (0.70, "phonetic_alias:\(alias)")
            }
        }

        // 8. Significant word overlap
        let spanWords = Set(lower.components(separatedBy: " ").filter { $0.count > 2 })
        let nameWords = Set(name.components(separatedBy: " ").filter { $0.count > 2 })
        let overlap = spanWords.intersection(nameWords).count
        if overlap > 0 {
            let ratio = Double(overlap) / Double(max(spanWords.count, nameWords.count))
            if ratio >= 0.50 { return (0.50 + ratio * 0.20, "word_overlap") }
        }

        return (0.0, "no_match")
    }

    // MARK: - Jaro-Winkler

    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let a = Array(s1), b = Array(s2)
        let matchDist = max(max(a.count, b.count) / 2 - 1, 0)

        var aMatched = Array(repeating: false, count: a.count)
        var bMatched = Array(repeating: false, count: b.count)
        var matches = 0

        for i in 0..<a.count {
            let lo = max(0, i - matchDist)
            let hi = min(i + matchDist + 1, b.count)
            guard lo < hi else { continue }
            for j in lo..<hi {
                guard !bMatched[j] && a[i] == b[j] else { continue }
                aMatched[i] = true; bMatched[j] = true
                matches += 1; break
            }
        }

        guard matches > 0 else { return 0.0 }

        var transpositions = 0, k = 0
        for i in 0..<a.count {
            guard aMatched[i] else { continue }
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let jaro = (Double(matches) / Double(a.count) +
                    Double(matches) / Double(b.count) +
                    Double(matches - transpositions / 2) / Double(matches)) / 3.0

        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) {
            if a[i] == b[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1.0 - jaro)
    }

    // MARK: - Soundex

    static func soundex(_ s: String) -> String {
        guard !s.isEmpty else { return "0000" }
        let chars = Array(s.lowercased())
        let table: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2",
            "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4",
            "m": "5", "n": "5", "r": "6",
        ]
        var result = [String(chars[0]).uppercased()]
        var prev: Character? = table[chars[0]]
        for ch in chars.dropFirst() {
            if let code = table[ch] {
                if code != prev { result.append(String(code)) }
                prev = code
            } else { prev = nil }
            if result.count == 4 { break }
        }
        while result.count < 4 { result.append("0") }
        return result.joined()
    }
}
