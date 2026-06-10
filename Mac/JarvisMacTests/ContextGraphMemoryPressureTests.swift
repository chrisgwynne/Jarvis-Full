import XCTest
@testable import JarvisMac

@MainActor
final class ContextGraphMemoryPressureTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        ContextGraph.shared.reset()
    }

    override func tearDown() async throws {
        ContextGraph.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeNode(
        title: String,
        trustTier: TrustTier = .system,
        confidence: Double = 0.8
    ) -> ContextNode {
        ContextNode(type: .memory, title: title, summary: "",
                    source: .system, confidence: confidence,
                    trustTier: trustTier, externalID: nil)
    }

    private func makeCandidate(title: String, id: UUID = UUID()) -> MemoryCandidate {
        var c = MemoryCandidate(
            type: .projectProgress,
            tier: .projectMemory,
            title: title,
            summary: "",
            rawText: title,
            confidence: 0.9,
            tags: [],
            createdAt: Date()
        )
        c.id = id
        return c
    }

    private func makeThread(title: String) -> TaskThread {
        TaskThread(
            id: UUID(),
            title: title,
            startedAt: Date(),
            lastActivityAt: Date(),
            apps: [],
            entities: [],
            errors: [],
            confidence: 0.9,
            isActive: true
        )
    }

    // MARK: - 1. Large ingestion stays within node cap

    func testLargeIngestion_staysWithinNodeCap() {
        let graph = ContextGraph()
        for i in 0..<700 {
            graph.upsertNode(makeNode(title: "Node \(i)", trustTier: .system))
        }
        XCTAssertEqual(graph.nodeCount, 700)

        let result = graph.prune(policy: PrunePolicy())

        XCTAssertLessThanOrEqual(graph.nodeCount, 600,
            "prune() must enforce the hard node cap")
        XCTAssertGreaterThan(result.nodesRemoved, 0)
    }

    // MARK: - 2. Repeated refresh does not grow unbounded

    func testRepeatedRefresh_doesNotGrowUnbounded() {
        let index = ProjectRelationshipIndex()
        // Fresh UUIDs on every call is the worst-case dedup failure scenario.
        index.getMemories = {
            (0..<600).map { i in self.makeCandidate(title: "Memory \(i)") }
        }

        for _ in 0..<5 { index.refresh() }

        XCTAssertLessThanOrEqual(ContextGraph.shared.nodeCount, 600,
            "Graph must not exceed hard cap across repeated refreshes")
    }

    // MARK: - 3. Cross-links are capped per thread

    func testCrossLinks_cappedAtMaxPerThread() {
        let index = ProjectRelationshipIndex()
        // "jarvis" is 6 chars — passes the 4-char significantWords filter.
        index.getTaskThreads = { [self.makeThread(title: "Building jarvis system")] }
        index.getMemories = {
            (0..<30).map { i in self.makeCandidate(title: "jarvis feature \(i)") }
        }

        index.refresh()

        let sameTopicEdges = ContextGraph.shared.edgesByID.values
            .filter { $0.type == .sameTopicAs }
        XCTAssertLessThanOrEqual(sameTopicEdges.count, 8,
            "Cross-links per thread must be capped at maxCrossLinksPerThread (8)")
    }

    // MARK: - 4. Duplicate cross-links don't double on repeat refresh

    func testCrossLinks_deduplicateOnRepeatRefresh() {
        let index = ProjectRelationshipIndex()
        let thread = makeThread(title: "Building jarvis memory store")
        // Fixed UUIDs → same externalIDs across refreshes → graph deduplication.
        let candidates = (0..<5).map { i -> MemoryCandidate in
            self.makeCandidate(title: "jarvis work item \(i)", id: UUID())
        }

        index.getTaskThreads = { [thread] }
        index.getMemories    = { candidates }

        index.refresh()
        let afterFirst = ContextGraph.shared.edgesByID.values
            .filter { $0.type == .sameTopicAs }.count

        index.refresh()
        let afterSecond = ContextGraph.shared.edgesByID.values
            .filter { $0.type == .sameTopicAs }.count

        XCTAssertEqual(afterFirst, afterSecond,
            "Repeated refresh with identical candidates must not duplicate cross-link edges")
    }

    // MARK: - 5. Large persisted graph prunes safely on load

    func testLargeGraph_prunesSafelyOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let saveGraph = ContextGraph()
        for i in 0..<750 {
            saveGraph.upsertNode(makeNode(title: "Stale node \(i)", trustTier: .system))
        }
        XCTAssertEqual(saveGraph.nodeCount, 750)

        ContextGraphPersistence(fileURL: url).save(graph: saveGraph)

        let loadGraph = ContextGraph()
        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.load(into: loadGraph)

        XCTAssertTrue(persistence.persistedGraphLoaded)
        XCTAssertLessThanOrEqual(loadGraph.nodeCount, 600,
            "Graph loaded from disk must be pruned to within cap")
    }

    // MARK: - 6. Diagnostics estimatedGraphBytes matches formula

    func testDiagnostics_estimatedBytesMatchFormula() {
        let diag = ContextGraphDiagnostics(
            nodeCount: 100, edgeCount: 50,
            nodesByType: [:], edgesByType: [:],
            lastIngestionAt: nil, topActiveProject: nil,
            activeContinuityChainLength: 0,
            contextBudgetBySource: [:],
            excludedContextCount: 0, generatedAt: Date(),
            persistedGraphLoaded: false, lastSaveTime: nil,
            lastPruneResult: nil, nodeCap: 600, edgeCap: 1200,
            focusConfidence: 0, previousFocusProject: nil,
            rankedNodeCount: 0, suppressedNodeCount: 0,
            graphSafeMode: false, lastRefreshDuration: 0,
            safeModeSkipCount: 0
        )
        XCTAssertEqual(diag.estimatedGraphBytes, 100 * 300 + 50 * 150)
    }

    // MARK: - 7. Safe mode engages at threshold and blocks ingestion

    func testSafeMode_engagesAndBlocksIngestion() {
        // Pre-fill graph to just above the safe-mode threshold (500 nodes).
        for i in 0..<505 {
            ContextGraph.shared.upsertNode(makeNode(title: "Pre-existing \(i)"))
        }
        let countBefore = ContextGraph.shared.nodeCount
        XCTAssertGreaterThanOrEqual(countBefore, 500)

        let index = ProjectRelationshipIndex()
        index.getMemories = {
            (0..<100).map { i in self.makeCandidate(title: "New memory \(i)") }
        }
        index.refresh()

        XCTAssertTrue(index.graphSafeMode,
            "graphSafeMode must engage when nodeCount >= safeModeNodeThreshold")
        // After a prune-only safe-mode pass the count should not have grown above cap.
        XCTAssertLessThanOrEqual(ContextGraph.shared.nodeCount, 600)
    }

    // MARK: - 8. Apple Notes nodes use .synced tier (prunable)

    func testAppleNoteNodes_useSyncedTier() {
        // .userEdited nodes are never pruned — Apple Notes must use .synced so they
        // remain eligible for eviction when the graph approaches capacity.
        let handler = NotesIntentHandler(renderer: ResponseRenderer(store: ResponseTemplateStore()))
        var captured: ContextNode?
        handler.ingestNode = { node in captured = node }

        handler.ingestNoteNode(title: "Sprint planning notes", body: "Build the memory system.")
        XCTAssertEqual(captured?.trustTier, .synced,
            "Apple Notes nodes must use .synced tier so they can be pruned when the graph is over cap")
        XCTAssertNotEqual(captured?.trustTier, .userEdited,
            ".userEdited is never pruned — using it for imported notes causes unbounded growth")
    }

    // MARK: - 9. Obsidian note nodes use .synced tier (prunable)

    func testObsidianNoteNodes_useSyncedTier() {
        let index = ProjectRelationshipIndex()
        let note  = ObsidianNote(
            id: "sprint-planning",
            title: "Sprint Planning",
            url: URL(fileURLWithPath: "/tmp/Sprint Planning.md"),
            modifiedAt: Date(),
            rawContent: "Plan the sprint.",
            body: "Plan the sprint.",
            tags: ["jarvis"],
            wikilinks: []
        )
        index.ingestObsidianNotes([note])

        let obsidianNodes = ContextGraph.shared.nodes(ofType: .obsidianNote)
        XCTAssertFalse(obsidianNodes.isEmpty, "Should have ingested one obsidian note")
        XCTAssertTrue(obsidianNodes.allSatisfy { $0.trustTier == .synced },
            "Obsidian note nodes must use .synced tier so they can be pruned under pressure")
    }

    // MARK: - 10. 200 Apple Notes stay within cap (synced tier is prunable)

    func testManyAppleNotes_stayWithinCap() {
        let index = ProjectRelationshipIndex()
        // Simulate 200 distinct Apple Note nodes entering via ingestNoteNode calls
        for i in 0..<200 {
            let node = ContextNode(
                type:       .appleNote,
                title:      "Apple Note \(i)",
                summary:    "Content of note \(i)",
                source:     .appleNotes,
                confidence: 0.90,
                trustTier:  .synced,
                externalID: "applenote:apple-note-\(i)"
            )
            ContextGraph.shared.upsertNode(node)
        }
        // Trigger a refresh which will prune if over cap
        index.refresh()

        XCTAssertLessThanOrEqual(ContextGraph.shared.nodeCount, 600,
            "200 Apple Note nodes (.synced) must be pruneable and not push graph over cap")
    }

    // MARK: - 11. Oversized on-disk file is rejected without OOM

    func testOversizedFile_isRejectedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a file larger than maxLoadFileSizeBytes (5 MB)
        let sixMB = Data(repeating: UInt8(ascii: "x"), count: 6 * 1024 * 1024)
        try sixMB.write(to: url)

        let graph       = ContextGraph()
        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.load(into: graph)

        XCTAssertFalse(persistence.persistedGraphLoaded,
            "Oversized file must be rejected — cold start instead of OOM")
        XCTAssertEqual(graph.nodeCount, 0,
            "Graph must be empty after rejecting an oversized file")
    }

    // MARK: - 12. safeModeSkipCount increments on safe-mode trigger

    func testSafeModeSkipCount_incrementsOnSafeModeRefresh() {
        // Fill graph to above the safe-mode threshold
        for i in 0..<505 {
            ContextGraph.shared.upsertNode(makeNode(title: "Pre-fill \(i)"))
        }
        let index = ProjectRelationshipIndex()
        XCTAssertEqual(index.safeModeSkipCount, 0)

        index.refresh()
        XCTAssertEqual(index.safeModeSkipCount, 1)

        index.refresh()
        XCTAssertEqual(index.safeModeSkipCount, 2)
    }

    // MARK: - 8. pbxproj UUID uniqueness regression guard

}
