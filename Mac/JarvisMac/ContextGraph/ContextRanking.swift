import Foundation

// MARK: - RankingContext

/// Contextual signals used to boost node relevance scores during ranking.
struct RankingContext {
    /// Display names of currently active / recently used apps (lowercased).
    let activeApps: Set<String>
    /// Significant keywords extracted from the current focus project title.
    let focusKeywords: Set<String>
    /// Reference timestamp for recency calculations.
    let now: Date

    init(
        activeApps:    Set<String> = [],
        focusKeywords: Set<String> = [],
        now:           Date        = Date()
    ) {
        self.activeApps    = Set(activeApps.map    { $0.lowercased() })
        self.focusKeywords = Set(focusKeywords.map { $0.lowercased() })
        self.now           = now
    }
}

// MARK: - NodeScore

/// Relevance score breakdown for a single ContextNode.
///
/// The `total` is a weighted composite of five orthogonal dimensions.
/// `explanation` produces a human-readable string for logs and diagnostics.
struct NodeScore {
    let node: ContextNode
    /// Composite relevance score in [0, 1].
    let total: Double
    // --- Component dimensions ---
    let recency:        Double   // freshness: full score <48h, zero at 96h
    let confidence:     Double   // raw node confidence
    let trustFactor:    Double   // trust-tier factor (see ContextRanking.trustScore)
    let corroboration:  Double   // cross-source neighbour diversity
    let focusAlignment: Double   // keyword + app overlap with current focus

    var explanation: String {
        "\(f(total)) [rec=\(f(recency)) conf=\(f(confidence)) "
        + "trust=\(f(trustFactor)) corr=\(f(corroboration)) focus=\(f(focusAlignment))]"
    }

    private func f(_ v: Double) -> String { String(format: "%.2f", v) }
}

// MARK: - ContextRanking

/// Deterministic, explainable relevance scoring for ContextGraph nodes.
///
/// All weights and thresholds are named constants — no magic numbers inline.
/// Scoring is purely arithmetic; no ML, no external calls, no side effects.
///
/// **Usage**
/// ```swift
/// let ctx = RankingContext(activeApps: activeApps, focusKeywords: keywords)
/// let scored = ContextRanking.rank(nodes: candidates, relativeTo: graph, context: ctx)
/// let top3 = scored.prefix(3)
/// ```
enum ContextRanking {

    // MARK: - Weights (must sum to 1.0)

    static let recencyWeight:       Double = 0.25
    static let confidenceWeight:    Double = 0.25
    static let trustWeight:         Double = 0.20
    static let corroborationWeight: Double = 0.15
    static let focusWeight:         Double = 0.15

    /// Full recency score within this many hours; zero at 2×.
    static let recencyHalfLifeHours: Double = 48

    // MARK: - Entry Point

    /// Returns `nodes` sorted by composite relevance (high → low).
    @MainActor
    static func rank(
        nodes:      [ContextNode],
        relativeTo  graph: ContextGraph,
        context:    RankingContext
    ) -> [NodeScore] {
        nodes
            .map  { scoreNode($0, graph: graph, context: context) }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Scoring

    /// Computes a `NodeScore` for a single node.  All sub-scorers are pure functions.
    @MainActor
    static func scoreNode(
        _ node:    ContextNode,
        graph:     ContextGraph,
        context:   RankingContext
    ) -> NodeScore {
        let rec   = recencyScore(node, now: context.now)
        let conf  = node.confidence
        let trust = trustScore(node.trustTier)
        let corr  = corroborationScore(node, graph: graph)
        let focus = focusScore(node, context: context)

        let total = rec  * recencyWeight
                  + conf * confidenceWeight
                  + trust * trustWeight
                  + corr * corroborationWeight
                  + focus * focusWeight

        return NodeScore(
            node:          node,
            total:         min(max(total, 0), 1),
            recency:       rec,
            confidence:    conf,
            trustFactor:   trust,
            corroboration: corr,
            focusAlignment: focus
        )
    }

    // MARK: - Component Scorers

    /// Full score for nodes updated within `recencyHalfLifeHours`; linear decay
    /// to zero at 2× the half-life.
    private static func recencyScore(_ node: ContextNode, now: Date) -> Double {
        let ageHours = now.timeIntervalSince(node.updatedAt) / 3600
        return max(0, 1 - ageHours / recencyHalfLifeHours)
    }

    /// Maps TrustTier to a numeric factor.  `userEdited` is the gold standard.
    static func trustScore(_ tier: TrustTier) -> Double {
        switch tier {
        case .system:     return 0.60
        case .synced:     return 0.75
        case .userEdited: return 1.00
        case .inferred:   return 0.35
        }
    }

    /// Measures how many distinct `ContextSource`s appear among the node's
    /// neighbours.  Each distinct source contributes ~0.33, capped at 1.0.
    /// A node mentioned by GitHub, Obsidian, AND a task thread scores ~1.0.
    @MainActor
    private static func corroborationScore(_ node: ContextNode, graph: ContextGraph) -> Double {
        let sources = Set(graph.neighbours(of: node.id).map(\.source))
        return min(Double(sources.count) * 0.33, 1.0)
    }

    /// Boosts nodes whose title/summary keywords or metadata app references
    /// overlap with the current focus project / active app set.
    private static func focusScore(_ node: ContextNode, context: RankingContext) -> Double {
        let hasKeywords = !context.focusKeywords.isEmpty
        let hasApps     = !context.activeApps.isEmpty
        guard hasKeywords || hasApps else { return 0 }

        let nodeWords = significantWords(in: node.title + " " + node.summary)
        let nodeApps  = Set(node.metadata.values
            .flatMap { $0.lowercased().components(separatedBy: .whitespaces) })

        let topicHit = hasKeywords && !nodeWords.isDisjoint(with: context.focusKeywords)
        let appHit   = hasApps     && !nodeApps.isDisjoint(with: context.activeApps)

        switch (topicHit, appHit) {
        case (true,  true):  return 1.0
        case (true,  false): return 0.65
        case (false, true):  return 0.40
        case (false, false): return 0.0
        }
    }

    // MARK: - Helpers

    /// Tokenises `text` into lowercase words of at least 4 characters.
    /// `internal` so `ProjectRelationshipIndex` can build focus keyword sets.
    static func significantWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
    }
}
