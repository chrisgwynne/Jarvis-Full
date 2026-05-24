import XCTest
@testable import JarvisMac

@MainActor
final class ContextGraphTests: XCTestCase {

    private var graph: ContextGraph!
    private var index: ProjectRelationshipIndex!

    override func setUp() async throws {
        try await super.setUp()
        graph = ContextGraph()
        index = ProjectRelationshipIndex()
    }

    // MARK: - ContextGraph: node dedup

    func testNodeDedup_sameExternalIDAndType_updatesInPlace() {
        let n1 = ContextNode(type: .memory, title: "First", summary: "v1",
                             source: .conversationMemory, confidence: 0.5,
                             trustTier: .system, externalID: "mem:001")
        let id1 = graph.upsertNode(n1)

        let n2 = ContextNode(type: .memory, title: "Second", summary: "v2",
                             source: .conversationMemory, confidence: 0.9,
                             trustTier: .system, externalID: "mem:001")
        let id2 = graph.upsertNode(n2)

        XCTAssertEqual(id1, id2, "Same external ID must reuse the original UUID")
        XCTAssertEqual(graph.nodeCount, 1)
        XCTAssertEqual(graph.node(for: id1)?.title, "Second")
        XCTAssertEqual(graph.node(for: id1)?.confidence, 0.9)
    }

    func testNodeDedup_differentTypes_insertsSeparately() {
        let n1 = ContextNode(type: .memory, title: "A", summary: "", source: .system,
                             confidence: 0.8, trustTier: .system, externalID: "shared:001")
        let n2 = ContextNode(type: .project, title: "A", summary: "", source: .system,
                             confidence: 0.8, trustTier: .system, externalID: "shared:001")
        graph.upsertNode(n1)
        graph.upsertNode(n2)
        XCTAssertEqual(graph.nodeCount, 2, "Different types with same externalID are distinct nodes")
    }

    func testNodeDedup_noExternalID_alwaysInserts() {
        let n1 = ContextNode(type: .memory, title: "A", summary: "", source: .system,
                             confidence: 0.5, trustTier: .system, externalID: nil)
        let n2 = ContextNode(type: .memory, title: "B", summary: "", source: .system,
                             confidence: 0.5, trustTier: .system, externalID: nil)
        graph.upsertNode(n1)
        graph.upsertNode(n2)
        XCTAssertEqual(graph.nodeCount, 2)
    }

    // MARK: - ContextGraph: edge dedup

    func testEdgeMerge_sameFromToType_deduplicates() {
        let a = graph.upsertNode(ContextNode(type: .memory, title: "A", summary: "",
                                             source: .system, confidence: 0.5, trustTier: .system))
        let b = graph.upsertNode(ContextNode(type: .project, title: "B", summary: "",
                                             source: .system, confidence: 0.5, trustTier: .system))

        let e1 = ContextEdge(from: a, to: b, type: .belongsToProject, confidence: 0.6,
                              evidence: "first")
        let e2 = ContextEdge(from: a, to: b, type: .belongsToProject, confidence: 0.9,
                              evidence: "second")
        let id1 = graph.upsertEdge(e1)
        let id2 = graph.upsertEdge(e2)

        XCTAssertEqual(id1, id2, "Duplicate (from, to, type) must reuse the first edge ID")
        XCTAssertEqual(graph.edgeCount, 1)
        XCTAssertEqual(graph.edgesByID[id1]?.confidence, 0.9, "Higher confidence should win")
    }

    func testEdgeMerge_differentType_insertsSeparately() {
        let a = graph.upsertNode(ContextNode(type: .memory, title: "A", summary: "",
                                             source: .system, confidence: 0.5, trustTier: .system))
        let b = graph.upsertNode(ContextNode(type: .project, title: "B", summary: "",
                                             source: .system, confidence: 0.5, trustTier: .system))

        graph.upsertEdge(ContextEdge(from: a, to: b, type: .belongsToProject, evidence: "x"))
        graph.upsertEdge(ContextEdge(from: a, to: b, type: .sameTopicAs, evidence: "y"))

        XCTAssertEqual(graph.edgeCount, 2)
    }

    // MARK: - ContextGraph: neighbours

    func testRelated_returnsConnectedNodes() {
        let mem = graph.upsertNode(ContextNode(type: .memory, title: "M", summary: "",
                                               source: .system, confidence: 0.7, trustTier: .system))
        let proj = graph.upsertNode(ContextNode(type: .project, title: "P", summary: "",
                                                source: .system, confidence: 0.7, trustTier: .system))
        let unrelated = graph.upsertNode(ContextNode(type: .activeApp, title: "U", summary: "",
                                                     source: .system, confidence: 0.5, trustTier: .system))

        graph.upsertEdge(ContextEdge(from: mem, to: proj, type: .belongsToProject, evidence: "test"))

        let neighbours = graph.neighbours(of: mem)
        XCTAssertTrue(neighbours.contains(where: { $0.id == proj }))
        XCTAssertFalse(neighbours.contains(where: { $0.id == unrelated }))
    }

    func testRelated_incomingEdgeAlsoCountsAsNeighbour() {
        let source = graph.upsertNode(ContextNode(type: .taskThread, title: "T", summary: "",
                                                  source: .taskThread, confidence: 0.8, trustTier: .system))
        let target = graph.upsertNode(ContextNode(type: .memory, title: "M", summary: "",
                                                  source: .conversationMemory, confidence: 0.7, trustTier: .system))
        graph.upsertEdge(ContextEdge(from: source, to: target, type: .relatesTo, evidence: "test"))

        let targetNeighbours = graph.neighbours(of: target)
        XCTAssertTrue(targetNeighbours.contains(where: { $0.id == source }),
                      "Incoming edge should expose the source as a neighbour of the target")
    }

    // MARK: - ProjectRelationshipIndex: empty ingestion

    func testEmptyIngestion_doesNotCrash() {
        index.ingestTaskThreads([])
        index.ingestMemories([])
        index.ingestObsidianNotes([])
        index.ingestExecutionTraces([])
        // No assertion needed — just must not throw / trap
    }

    // MARK: - ProjectRelationshipIndex: activeContinuityChain

    func testActiveContinuityChain_linkedNodes_propagates() {
        // Seed a task thread + a project linked to it
        let thread = TaskThread(
            id: UUID(), title: "Jarvis Sprint",
            startedAt: Date(), lastActivityAt: Date(),
            apps: ["Xcode"], entities: [], errors: [],
            confidence: 0.9, isActive: true
        )
        index.ingestTaskThreads([thread])

        let chain = index.activeContinuityChain(limit: 5)
        XCTAssertFalse(chain.isEmpty, "Active thread should anchor the chain")
        XCTAssertEqual(chain.first?.type, .taskThread)
    }

    // MARK: - ProjectRelationshipIndex: explainProvenance

    func testExplainProvenance_unknownNode_returnsEmptyResult() {
        let prov = index.explainProvenance(for: UUID())
        XCTAssertEqual(prov.nodeTitle, "Unknown")
        XCTAssertTrue(prov.entries.isEmpty)
    }

    func testExplainProvenance_knownNode_includesAnchorEntry() {
        // Wire a real node via the shared graph that index reads
        let sharedGraph = ContextGraph.shared
        let node = ContextNode(type: .memory, title: "ProvenanceTest", summary: "test summary",
                               source: .conversationMemory, confidence: 0.8,
                               trustTier: .userEdited, externalID: "prov:test:001")
        let nodeID = sharedGraph.upsertNode(node)

        let prov = ProjectRelationshipIndex.shared.explainProvenance(for: nodeID, charBudget: 500)
        XCTAssertEqual(prov.nodeTitle, "ProvenanceTest")
        XCTAssertFalse(prov.entries.isEmpty)
        XCTAssertEqual(prov.entries.first?.reason, "anchor node")

        // Cleanup
        sharedGraph.removeNode(id: nodeID)
    }

    // MARK: - ContextProvenance: summary

    func testContextProvenance_summary_containsNodeTitle() {
        let entry = ProvenanceEntry(source: .conversationMemory, nodeType: .memory,
                                    nodeID: UUID(), nodeTitle: "My Memory",
                                    trustTier: .userEdited, charCount: 100, reason: "anchor node")
        let prov = ContextProvenance(
            nodeID: UUID(), nodeTitle: "Root Node",
            entries: [entry], totalCharBudget: 2000, usedCharBudget: 100,
            truncatedSources: [], excludedSources: [], generatedAt: Date()
        )
        XCTAssertTrue(prov.summary.contains("Root Node"))
        XCTAssertTrue(prov.summary.contains("My Memory"))
    }

    // MARK: - ContextGraphDiagnostics: oneLiner

    func testContextGraphDiagnostics_oneLiner_includesCounts() {
        let diag = ContextGraphDiagnostics(
            nodeCount: 42, edgeCount: 17,
            nodesByType: [:], edgesByType: [:],
            lastIngestionAt: Date(), topActiveProject: "Jarvis",
            activeContinuityChainLength: 3, contextBudgetBySource: [:],
            excludedContextCount: 0, generatedAt: Date(),
            persistedGraphLoaded: false, lastSaveTime: nil,
            lastPruneResult: nil, nodeCap: 600, edgeCap: 1200,
            focusConfidence: 0, previousFocusProject: nil,
            rankedNodeCount: 0, suppressedNodeCount: 0,
            graphSafeMode: false, lastRefreshDuration: 0,
            safeModeSkipCount: 0
        )
        XCTAssertTrue(diag.oneLiner.contains("42"))
        XCTAssertTrue(diag.oneLiner.contains("17"))
    }

    // MARK: - TrustTier ordering

    func testTrustTier_comparableOrdering() {
        XCTAssertLessThan(TrustTier.system, TrustTier.synced)
        XCTAssertLessThan(TrustTier.synced, TrustTier.userEdited)
        XCTAssertLessThan(TrustTier.userEdited, TrustTier.inferred)
    }
}
