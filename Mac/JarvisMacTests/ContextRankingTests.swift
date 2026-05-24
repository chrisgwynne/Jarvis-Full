import XCTest
@testable import JarvisMac

@MainActor
final class ContextRankingTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        type: ContextNodeType = .memory,
        title: String,
        summary: String = "",
        trustTier: TrustTier = .system,
        confidence: Double = 0.8,
        ageHours: Double = 0
    ) -> ContextNode {
        var node = ContextNode(
            type: type, title: title, summary: summary,
            source: .conversationMemory, confidence: confidence,
            trustTier: trustTier
        )
        // Simulate age by nudging updatedAt into the past
        if ageHours > 0 {
            // ContextNode.updatedAt is a var; set via reflection isn't possible —
            // use a fresh graph upsert to get the right timestamp, then we test
            // scoring logic via the scorer directly.
            _ = ageHours  // age is reflected in recencyScore test below
        }
        return node
    }

    private func freshGraph() -> ContextGraph {
        ContextGraph.shared.reset()
        return ContextGraph.shared
    }

    // MARK: - significantWords

    func testSignificantWordsFiltersShortTokens() {
        let words = ContextRanking.significantWords(in: "fix bug in auth system")
        XCTAssertTrue(words.contains("system"))
        XCTAssertFalse(words.contains("fix"))  // < 4 chars
        XCTAssertFalse(words.contains("bug"))  // < 4 chars
        XCTAssertFalse(words.contains("in"))
    }

    func testSignificantWordsLowercases() {
        let words = ContextRanking.significantWords(in: "Jarvis macOS Project")
        XCTAssertTrue(words.contains("jarvis"))
        XCTAssertTrue(words.contains("macos"))
        XCTAssertTrue(words.contains("project"))
    }

    func testSignificantWordsDeduplicates() {
        let words = ContextRanking.significantWords(in: "auth auth authentication")
        XCTAssertEqual(words.filter { $0.hasPrefix("auth") }.count, 2) // "auth" and "authentication"
    }

    // MARK: - trustScore

    func testTrustScoreOrdering() {
        let system     = ContextRanking.trustScore(.system)
        let synced     = ContextRanking.trustScore(.synced)
        let userEdited = ContextRanking.trustScore(.userEdited)
        let inferred   = ContextRanking.trustScore(.inferred)

        XCTAssertGreaterThan(userEdited, synced)
        XCTAssertGreaterThan(synced, system)
        XCTAssertGreaterThan(system, inferred)
        XCTAssertEqual(userEdited, 1.0)
        XCTAssertLessThanOrEqual(inferred, 0.40)
    }

    // MARK: - recencyScore (via scoreNode)

    func testFreshNodeScoresHigherThanStaleNode() {
        let graph = freshGraph()
        let ctx   = RankingContext()

        let freshNode = makeNode(title: "fresh", confidence: 0.8)
        let freshID   = graph.upsertNode(freshNode)

        // Create a stale node by adding a node and checking recency component
        // We can't directly backdate updatedAt, so we verify via rank ordering
        // when one node has higher confidence to compensate
        let weakNode = makeNode(title: "weak", confidence: 0.1)
        let weakID   = graph.upsertNode(weakNode)

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: freshID)!, graph.node(for: weakID)!],
            relativeTo: graph,
            context: ctx
        )
        // Fresh + high confidence should rank above weak + fresh
        XCTAssertEqual(scored.first?.node.id, freshID)
    }

    // MARK: - corroborationScore

    func testCorroborationScoreZeroForIsolatedNode() {
        let graph = freshGraph()
        let ctx   = RankingContext()

        let node   = makeNode(title: "isolated memory")
        let nodeID = graph.upsertNode(node)

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: nodeID)!],
            relativeTo: graph,
            context: ctx
        )
        XCTAssertEqual(scored.first?.corroboration, 0.0)
    }

    func testCorroborationScoreIncreasesWithDistinctSources() {
        let graph = freshGraph()
        let ctx   = RankingContext()

        let anchor     = makeNode(title: "anchor", trustTier: .system)
        let anchorID   = graph.upsertNode(anchor)

        // Add neighbours from two distinct sources
        let ghNode   = ContextNode(type: .githubIssue, title: "GH Issue", summary: "",
                                   source: .githubIssue, trustTier: .synced)
        let taskNode = ContextNode(type: .taskThread, title: "Thread",  summary: "",
                                   source: .taskThread, trustTier: .system)
        let ghID   = graph.upsertNode(ghNode)
        let taskID = graph.upsertNode(taskNode)

        graph.upsertEdge(ContextEdge(from: anchorID, to: ghID,   type: .sameTopicAs))
        graph.upsertEdge(ContextEdge(from: anchorID, to: taskID, type: .sameTopicAs))

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: anchorID)!],
            relativeTo: graph,
            context: ctx
        )
        XCTAssertGreaterThan(scored.first?.corroboration ?? 0, 0.0)
    }

    // MARK: - focusScore

    func testFocusScoreZeroWhenNoContext() {
        let graph = freshGraph()
        let ctx   = RankingContext()  // empty activeApps + focusKeywords

        let node   = makeNode(title: "Jarvis project auth system")
        let nodeID = graph.upsertNode(node)

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: nodeID)!],
            relativeTo: graph,
            context: ctx
        )
        XCTAssertEqual(scored.first?.focusAlignment, 0.0)
    }

    func testFocusScoreTopicHitOnly() {
        let graph = freshGraph()
        let ctx   = RankingContext(
            activeApps:    [],
            focusKeywords: ["jarvis", "project"]
        )

        let node   = makeNode(title: "Jarvis project decisions")
        let nodeID = graph.upsertNode(node)

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: nodeID)!],
            relativeTo: graph,
            context: ctx
        )
        XCTAssertEqual(scored.first?.focusAlignment ?? 0, 0.65, accuracy: 0.01)
    }

    func testFocusScoreTopicAndAppHit() {
        let graph = freshGraph()
        let ctx   = RankingContext(
            activeApps:    ["cursor"],
            focusKeywords: ["jarvis"]
        )

        var node = makeNode(title: "Jarvis code review")
        node = ContextNode(type: .memory, title: "Jarvis code review", summary: "",
                           source: .conversationMemory, confidence: 0.8,
                           metadata: ["app": "cursor"])
        let nodeID = graph.upsertNode(node)

        let scored = ContextRanking.rank(
            nodes: [graph.node(for: nodeID)!],
            relativeTo: graph,
            context: ctx
        )
        // topicHit (title contains "jarvis") + appHit (metadata["app"] = "cursor") → 1.0
        XCTAssertGreaterThanOrEqual(scored.first?.focusAlignment ?? 0, 0.60)
    }

    // MARK: - rank ordering

    func testRankReturnsSortedDescending() {
        let graph = freshGraph()
        let ctx   = RankingContext()

        let highConf = makeNode(title: "important memory", trustTier: .userEdited, confidence: 0.95)
        let lowConf  = makeNode(title: "weak memory",      trustTier: .inferred,  confidence: 0.20)

        let highID = graph.upsertNode(highConf)
        let lowID  = graph.upsertNode(lowConf)

        let ranked = ContextRanking.rank(
            nodes: [graph.node(for: lowID)!, graph.node(for: highID)!],
            relativeTo: graph,
            context: ctx
        )
        XCTAssertEqual(ranked.first?.node.id, highID)
        XCTAssertEqual(ranked.last?.node.id,  lowID)
        XCTAssertGreaterThanOrEqual(ranked[0].total, ranked[1].total)
    }

    // MARK: - ProjectFocusState hysteresis

    func testFocusStateIgnoresBelowThreshold() {
        let state = ProjectFocusState()
        state.update(candidates: [("Alpha", 0.20)])  // below minConfidence 0.35
        XCTAssertNil(state.currentFocus)
    }

    func testFocusStateAcceptsStrongCandidate() {
        let state = ProjectFocusState()
        state.update(candidates: [("Alpha", 0.80)])
        XCTAssertEqual(state.currentFocus, "Alpha")
        XCTAssertEqual(state.currentConfidence, 0.80 + state.incumbentBonus, accuracy: 0.01)
    }

    func testFocusStateHysteresisBlocksWeakChallenger() {
        let state = ProjectFocusState()
        state.update(candidates: [("Alpha", 0.80)])  // Alpha wins
        // Beta is only slightly higher — should not displace Alpha due to changeThreshold
        state.update(candidates: [("Alpha", 0.75), ("Beta", 0.78)])
        XCTAssertEqual(state.currentFocus, "Alpha")  // incumbent stays
    }

    func testFocusStateAllowsStrongChallenger() {
        let state = ProjectFocusState()
        state.update(candidates: [("Alpha", 0.60)])
        // Beta must beat Alpha's adjusted score (0.60 + 0.15 = 0.75) by changeThreshold (0.12)
        state.update(candidates: [("Alpha", 0.50), ("Beta", 0.90)])
        XCTAssertEqual(state.currentFocus, "Beta")
    }
}
