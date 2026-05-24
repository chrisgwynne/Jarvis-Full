import Foundation

// MARK: - HybridEntityMatcher

@MainActor
enum HybridEntityMatcher {

    private static let clarificationMargin = 0.15
    private static let minimumConfidence   = 0.40

    struct MatchResult {
        let node: EntityMemNode
        let confidence: Double
        let matchStrategy: String
    }

    // MARK: - Match

    static func match(
        phrase: String,
        in graph: EntityMemoryGraph,
        kindFilter: EntityMemKind? = nil,
        topN: Int = 5
    ) -> [MatchResult] {
        let lower = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        let candidates = graph.all().filter {
            !$0.isExpired && (kindFilter == nil || $0.entityKind == kindFilter)
        }
        return candidates
            .compactMap { score(phrase: lower, against: $0) }
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(topN).map { $0 }
    }

    static func bestMatch(
        phrase: String,
        in graph: EntityMemoryGraph,
        kindFilter: EntityMemKind? = nil
    ) -> ResolutionResult {
        let matches = match(phrase: phrase, in: graph, kindFilter: kindFilter)
        guard let top = matches.first else { return .empty }
        let second = matches.dropFirst().first
        let margin = second.map { top.confidence - $0.confidence } ?? 1.0
        let needsClarification = margin < clarificationMargin && top.confidence < 0.90
        return ResolutionResult(
            entity: top.node,
            confidence: top.confidence,
            source: top.matchStrategy,
            candidates: matches.map(\.node),
            needsClarification: needsClarification,
            clarificationPrompt: needsClarification
                ? buildClarification(top: top.node, second: second?.node) : nil
        )
    }

    // MARK: - Recency / salience shortcuts

    static func mostRecentOf(kind: EntityMemKind, in graph: EntityMemoryGraph) -> EntityMemNode? {
        graph.byKind(kind, limit: 1).first
    }

    static func mostSalient(in graph: EntityMemoryGraph) -> EntityMemNode? {
        graph.topSalient(limit: 1).first
    }

    // MARK: - Private scoring

    private static func score(phrase: String, against node: EntityMemNode) -> MatchResult? {
        let canonical = node.canonicalName.lowercased()

        if phrase == canonical {
            return MatchResult(node: node, confidence: 1.0, matchStrategy: "exact")
        }
        for alias in node.aliases where phrase == alias.lowercased() {
            return MatchResult(node: node, confidence: 0.97, matchStrategy: "alias_exact")
        }
        if canonical.hasPrefix(phrase) || phrase.hasPrefix(canonical) {
            let ratio = Double(min(phrase.count, canonical.count)) /
                        Double(max(phrase.count, canonical.count))
            return MatchResult(node: node, confidence: 0.75 + ratio * 0.15, matchStrategy: "prefix")
        }
        for alias in node.aliases {
            let a = alias.lowercased()
            if a.hasPrefix(phrase) || phrase.hasPrefix(a) {
                let ratio = Double(min(phrase.count, a.count)) / Double(max(phrase.count, a.count))
                return MatchResult(node: node, confidence: 0.70 + ratio * 0.12,
                                   matchStrategy: "alias_prefix")
            }
        }
        if canonical.contains(phrase) || phrase.contains(canonical) {
            return MatchResult(node: node, confidence: 0.60, matchStrategy: "contains")
        }
        // Recency boost for short pronouns with fresh nodes
        if phrase.count <= 4 {
            let recency = node.currentRecencyScore()
            if recency > 0.8 {
                return MatchResult(node: node, confidence: 0.55 * recency, matchStrategy: "recency")
            }
        }
        // Word overlap
        let phraseWords = Set(phrase.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let canonWords  = Set(canonical.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let intersection = phraseWords.intersection(canonWords)
        if !intersection.isEmpty, !phraseWords.isEmpty {
            let overlap = Double(intersection.count) / Double(phraseWords.union(canonWords).count)
            if overlap >= 0.4 {
                return MatchResult(node: node, confidence: 0.45 + overlap * 0.25,
                                   matchStrategy: "word_overlap")
            }
        }
        return nil
    }

    private static func buildClarification(top: EntityMemNode, second: EntityMemNode?) -> String {
        guard let second else { return "Did you mean \(top.canonicalName)?" }
        return "Did you mean \(top.canonicalName) or \(second.canonicalName)?"
    }
}
