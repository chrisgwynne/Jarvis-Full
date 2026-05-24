import Foundation

/// Synchronous, data-driven phrase matcher.
///
/// Iterates every enabled `CommandDefinition` in the phrase store,
/// tries each enabled phrase against the normalized input, and returns
/// the highest-confidence `MatchedCommand`. Falls back to `nil` when
/// nothing clears the minimum thresholds so the existing deterministic
/// `IntentRouter` path can take over.
///
/// Value type — safe to call from any actor/thread as long as the
/// `definitions` snapshot is passed in.
struct CommandPhraseMatcher {

    /// Minimum similarity required for a `.fuzzy` match to succeed.
    var fuzzyThreshold: Double = 0.80

    // MARK: - Primary API

    func match(normalizedInput: String,
               definitions: [CommandDefinition]) -> MatchedCommand? {
        guard !normalizedInput.isEmpty else { return nil }

        var best: (match: MatchedCommand, tiebreaker: Double)? = nil

        for def in definitions where def.enabled {
            for phrase in def.phrases where phrase.enabled {
                guard let candidate = attempt(input: normalizedInput,
                                              phrase: phrase,
                                              definition: def) else { continue }
                // Tiebreaker combines confidence + a tiny bump from priority
                // so the user can express preference without overriding confidence.
                let tb = candidate.confidence + Double(phrase.priority) * 0.001
                if best == nil || tb > best!.tiebreaker {
                    best = (candidate, tb)
                }
            }
        }
        return best?.match
    }

    /// Returns near-miss candidates with confidence between 0.55 and
    /// `fuzzyThreshold`. Used for diagnostics and "did you mean" UI.
    func nearMisses(normalizedInput: String,
                    definitions: [CommandDefinition],
                    limit: Int = 5) -> [MatchedCommand] {
        guard !normalizedInput.isEmpty else { return [] }

        var candidates: [(MatchedCommand, Double)] = []

        for def in definitions where def.enabled {
            for phrase in def.phrases where phrase.enabled {
                let p = phrase.normalizedPhrase
                guard !p.isEmpty else { continue }
                let sim = Self.editSimilarity(normalizedInput, p)
                guard sim >= 0.55, sim < fuzzyThreshold else { continue }
                let m = MatchedCommand(
                    commandId: def.id,
                    displayName: def.displayName,
                    matchedPhrase: phrase.phrase,
                    normalizedInput: normalizedInput,
                    matchType: .fuzzy,
                    confidence: sim,
                    reason: "near miss (sim=\(String(format: "%.2f", sim)))")
                candidates.append((m, sim))
            }
        }
        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Attempt a single phrase

    private func attempt(input: String,
                         phrase: CommandPhrase,
                         definition: CommandDefinition) -> MatchedCommand? {
        let p = phrase.normalizedPhrase
        guard !p.isEmpty else { return nil }

        switch phrase.matchType {

        case .exact:
            guard input == p else { return nil }
            return MatchedCommand(
                commandId: definition.id,
                displayName: definition.displayName,
                matchedPhrase: phrase.phrase,
                normalizedInput: input,
                matchType: .exact,
                confidence: 1.0,
                reason: "exact match (\"\(p)\")")

        case .contains:
            if input.contains(p) {
                let ratio = Double(p.count) / Double(max(input.count, 1))
                let conf = 0.70 + 0.25 * ratio
                return MatchedCommand(
                    commandId: definition.id,
                    displayName: definition.displayName,
                    matchedPhrase: phrase.phrase,
                    normalizedInput: input,
                    matchType: .contains,
                    confidence: conf,
                    reason: "input contains phrase (\"\(p)\")")
            }
            // Phrase encompasses input (input is a subset of the phrase)
            if p.contains(input) {
                let ratio = Double(input.count) / Double(max(p.count, 1))
                let conf = 0.70 + 0.20 * ratio
                return MatchedCommand(
                    commandId: definition.id,
                    displayName: definition.displayName,
                    matchedPhrase: phrase.phrase,
                    normalizedInput: input,
                    matchType: .contains,
                    confidence: conf,
                    reason: "phrase contains input (\"\(p)\")")
            }
            return nil

        case .startsWith:
            if input.hasPrefix(p) {
                return MatchedCommand(
                    commandId: definition.id,
                    displayName: definition.displayName,
                    matchedPhrase: phrase.phrase,
                    normalizedInput: input,
                    matchType: .startsWith,
                    confidence: 0.95,
                    reason: "input starts with phrase (\"\(p)\")")
            }
            if p.hasPrefix(input) {
                return MatchedCommand(
                    commandId: definition.id,
                    displayName: definition.displayName,
                    matchedPhrase: phrase.phrase,
                    normalizedInput: input,
                    matchType: .startsWith,
                    confidence: 0.80,
                    reason: "phrase starts with input (\"\(p)\")")
            }
            return nil

        case .regex:
            guard let re = try? NSRegularExpression(pattern: p,
                                                     options: .caseInsensitive) else {
                return nil
            }
            let range = NSRange(input.startIndex..., in: input)
            guard re.firstMatch(in: input, range: range) != nil else { return nil }
            return MatchedCommand(
                commandId: definition.id,
                displayName: definition.displayName,
                matchedPhrase: phrase.phrase,
                normalizedInput: input,
                matchType: .regex,
                confidence: 0.90,
                reason: "regex match (\"\(p)\")")

        case .fuzzy:
            let sim = Self.editSimilarity(input, p)
            guard sim >= fuzzyThreshold else { return nil }
            return MatchedCommand(
                commandId: definition.id,
                displayName: definition.displayName,
                matchedPhrase: phrase.phrase,
                normalizedInput: input,
                matchType: .fuzzy,
                confidence: sim,
                reason: "fuzzy match sim=\(String(format: "%.2f", sim)) (\"\(p)\")")
        }
    }

    // MARK: - String similarity (character-level Levenshtein)

    static func editSimilarity(_ a: String, _ b: String) -> Double {
        let ac = Array(a), bc = Array(b)
        let dist = levenshtein(ac, bc)
        let maxLen = max(ac.count, bc.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - Double(dist) / Double(maxLen)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                curr[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j], curr[j - 1], prev[j - 1])
            }
            prev = curr
        }
        return prev[n]
    }
}
