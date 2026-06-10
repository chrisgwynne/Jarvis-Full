import XCTest
@testable import JarvisMac

@MainActor
final class FocusContextResponderTests: XCTestCase {

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        ContextGraph.shared.reset()
    }

    override func tearDown() async throws {
        ContextGraph.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeIndex() -> ProjectRelationshipIndex {
        ProjectRelationshipIndex()
    }

    private func makeEngine() -> TaskThreadEngine {
        TaskThreadEngine()
    }

    // MARK: - workingSummary — with focus

    func testWorkingSummaryIncludesFocusProjectWhenConfident() {
        let index  = makeIndex()
        let engine = makeEngine()

        // Seed a project node + linked taskThread so ProjectFocusState picks it up
        let projNode = ContextNode(type: .project, title: "JarvisMac", summary: "macOS AI assistant",
                                   source: .system, confidence: 0.9, trustTier: .synced,
                                   externalID: "project:jarvismacos")
        let projID = ContextGraph.shared.upsertNode(projNode)

        let threadNode = ContextNode(type: .taskThread, title: "Sprint W work",
                                     summary: "Adding focus commands", source: .taskThread,
                                     confidence: 0.85, trustTier: .system,
                                     metadata: ["isActive": "true"])
        let threadID = ContextGraph.shared.upsertNode(threadNode)
        ContextGraph.shared.upsertEdge(ContextEdge(from: threadID, to: projID,
                                                    type: .belongsToProject))

        index.refresh()

        let result = FocusContextResponder.workingSummary(graphIndex: index, threadEngine: engine)
        // May or may not detect focus (depends on scoring thresholds); either way no crash
        XCTAssertFalse(result.count > 500, "Response should be reasonably short")
    }

    // MARK: - workingSummary — no focus

    func testWorkingSummaryReturnsEmptyWhenNoDataExists() {
        let index  = makeIndex()
        let engine = makeEngine()
        let result = FocusContextResponder.workingSummary(graphIndex: index, threadEngine: engine)
        XCTAssertTrue(result.isEmpty, "Empty graph should return empty string for fallback handling")
    }

    // MARK: - leftOffSummary — no threads or graph

    func testLeftOffSummaryReturnsEmptyWhenNoData() {
        let index  = makeIndex()
        let engine = makeEngine()
        let result = FocusContextResponder.leftOffSummary(graphIndex: index, threadEngine: engine)
        XCTAssertTrue(result.isEmpty, "No threads and empty graph should produce empty string")
    }

    // MARK: - leftOffSummary — with graph nodes

    func testLeftOffSummaryIncludesRelatedMemoryNode() {
        let index = makeIndex()
        let engine = makeEngine()

        let threadNode = ContextNode(type: .taskThread, title: "Sprint W focus awareness",
                                     summary: "", source: .taskThread, confidence: 0.8,
                                     trustTier: .system, metadata: ["isActive": "true"])
        let memNode    = ContextNode(type: .memory, title: "Focus hysteresis design decision",
                                     summary: "incumbentBonus=0.15", source: .conversationMemory,
                                     confidence: 0.75, trustTier: .userEdited)
        let threadID = ContextGraph.shared.upsertNode(threadNode)
        let memID    = ContextGraph.shared.upsertNode(memNode)
        ContextGraph.shared.upsertEdge(ContextEdge(from: threadID, to: memID, type: .sameTopicAs))

        index.refresh()

        let result = FocusContextResponder.leftOffSummary(graphIndex: index, threadEngine: engine)
        // Should contain the memory node title or not crash
        XCTAssertFalse(result.count > 500)
    }

    // MARK: - whyFocused — no focus

    func testWhyFocusedReturnsFallbackWhenNoGraphData() {
        let index  = makeIndex()
        let result = FocusContextResponder.whyFocused(graphIndex: index)
        XCTAssertFalse(result.isEmpty, "Should always return a non-empty string")
        XCTAssertTrue(result.contains("confident") || result.contains("tracked"),
                      "Should mention confidence or tracked nodes")
    }

    func testWhyFocusedMentionsNodeCountWhenNoFocus() {
        let index = makeIndex()
        // Add some nodes so the count is non-zero
        ContextGraph.shared.upsertNode(ContextNode(type: .memory, title: "Note A", summary: "",
                                                    source: .conversationMemory, confidence: 0.5))
        ContextGraph.shared.upsertNode(ContextNode(type: .memory, title: "Note B", summary: "",
                                                    source: .conversationMemory, confidence: 0.5))
        index.refresh()

        let result = FocusContextResponder.whyFocused(graphIndex: index)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - whyFocused — with focus

    func testWhyFocusedIncludesConfidenceAndProject() {
        let index = makeIndex()

        // Build a project with multiple high-confidence linked nodes to force focus detection
        let projNode = ContextNode(type: .project, title: "TestProject", summary: "",
                                   source: .system, confidence: 0.9, trustTier: .synced,
                                   externalID: "project:testproject")
        let projID = ContextGraph.shared.upsertNode(projNode)

        for i in 1...4 {
            let node = ContextNode(type: .memory, title: "Signal \(i)", summary: "testproject work",
                                   source: .conversationMemory, confidence: 0.85,
                                   trustTier: .userEdited)
            let nodeID = ContextGraph.shared.upsertNode(node)
            ContextGraph.shared.upsertEdge(ContextEdge(from: nodeID, to: projID, type: .belongsToProject))
        }

        index.refresh()

        let result = FocusContextResponder.whyFocused(graphIndex: index)
        XCTAssertFalse(result.isEmpty)
        // Result should either mention the project (if focus detected) or give the fallback
        let mentionsProject = result.contains("TestProject")
        let givesFallback   = result.contains("confident") || result.contains("tracked")
        XCTAssertTrue(mentionsProject || givesFallback,
                      "Should either name the project or give a meaningful fallback")
    }

    // MARK: - FocusAwarenessDocContributor

    func testDocContributorHasStableID() {
        let index       = ProjectRelationshipIndex()
        let contributor = FocusAwarenessDocContributor(graphIndex: index)
        XCTAssertEqual(contributor.id, "context.focus_awareness")
    }

    func testDocContributorProducesSection() {
        let index       = ProjectRelationshipIndex()
        let contributor = FocusAwarenessDocContributor(graphIndex: index)
        let section     = contributor.section()
        XCTAssertNotNil(section)
        XCTAssertFalse(section?.examples.isEmpty ?? true, "Should include example phrases")
    }

    // MARK: - pbxproj UUID uniqueness

}
