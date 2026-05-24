import XCTest
@testable import JarvisMac

@MainActor
final class ContextGraphPersistenceTests: XCTestCase {

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

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cg_test_\(UUID().uuidString).json")
    }

    private func makeNode(
        type: ContextNodeType = .memory,
        title: String,
        summary: String = "",
        trustTier: TrustTier = .system,
        confidence: Double = 0.8,
        externalID: String? = nil
    ) -> ContextNode {
        ContextNode(type: type, title: title, summary: summary,
                    source: .system, confidence: confidence,
                    trustTier: trustTier, externalID: externalID)
    }

    private func makeMemoryCandidate(title: String, summary: String = "") -> MemoryCandidate {
        MemoryCandidate(
            type: .projectProgress,
            tier: .projectMemory,
            title: title,
            summary: summary,
            rawText: title,
            confidence: 0.8,
            tags: [],
            createdAt: Date()
        )
    }

    private func makeTaskThread(title: String) -> TaskThread {
        TaskThread(
            id: UUID(),
            title: title,
            startedAt: Date(),
            lastActivityAt: Date(),
            apps: ["Xcode"],
            entities: [],
            errors: [],
            confidence: 0.9,
            isActive: true
        )
    }

    private func makeComposer(withGraph: Bool = false) -> JarvisAnswerComposer {
        JarvisAnswerComposer(
            llmRouter: LLMRouter(
                xai:      XAIProvider(baseURL: { "" }, modelName: { "" },
                                       enabled: { false }, apiKey: { nil }),
                miniMax:  MiniMaxProvider(baseURL: { "" }, modelName: { "" },
                                          enabled: { false }, apiKey: { nil }),
                gemini:   GeminiProvider(baseURL: { "" }, modelName: { "" },
                                         visionModel: { "" }, enabled: { false }, apiKey: { nil }),
                lmStudio: LMStudioProvider(baseURL: { "" }, modelName: { "" }, enabled: { false })
            ),
            contextBuilder: PersonalityContextBuilder(store: PersonalityFileStore()),
            activeContext:  ActiveContextRegistry.shared,
            graphIndex:     withGraph ? ProjectRelationshipIndex.shared : nil
        )
    }

    // MARK: - Persistence: save / load round-trip

    func testSaveAndLoad_roundTrip() throws {
        let url   = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Use isolated (non-shared) ContextGraph instances for pure persistence tests
        let graph = ContextGraph()
        let n1    = makeNode(title: "Alpha", externalID: "ext:alpha")
        let n2    = makeNode(title: "Beta",  externalID: "ext:beta")
        let id1   = graph.upsertNode(n1)
        let id2   = graph.upsertNode(n2)
        graph.upsertEdge(ContextEdge(from: id1, to: id2, type: .relatesTo))

        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.save(graph: graph)
        XCTAssertNotNil(persistence.lastSaveTime)

        let graph2       = ContextGraph()
        let persistence2 = ContextGraphPersistence(fileURL: url)
        persistence2.load(into: graph2)

        XCTAssertTrue(persistence2.persistedGraphLoaded)
        XCTAssertEqual(graph2.nodeCount, 2)
        XCTAssertEqual(graph2.edgeCount, 1)
        XCTAssertNotNil(graph2.findByExternalID("ext:alpha", type: .memory))
        XCTAssertNotNil(graph2.findByExternalID("ext:beta",  type: .memory))
    }

    func testLoad_corruptJSON_doesNotCrash() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try? "not valid json at all".data(using: .utf8)!.write(to: url)

        let graph       = ContextGraph()
        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.load(into: graph)

        XCTAssertFalse(persistence.persistedGraphLoaded)
        XCTAssertEqual(graph.nodeCount, 0)
    }

    func testLoad_missingFile_doesNotCrash() {
        let url         = tmpURL()   // never written
        let graph       = ContextGraph()
        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.load(into: graph)

        XCTAssertFalse(persistence.persistedGraphLoaded)
        XCTAssertEqual(graph.nodeCount, 0)
    }

    func testLoad_danglingEdges_filtered() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let graph = ContextGraph()
        let id1   = graph.upsertNode(makeNode(title: "Keep",   externalID: "e:keep"))
        let id2   = graph.upsertNode(makeNode(title: "Remove", externalID: "e:rm"))
        graph.upsertEdge(ContextEdge(from: id1, to: id2, type: .relatesTo))

        let persistence = ContextGraphPersistence(fileURL: url)
        persistence.save(graph: graph)

        // Remove one node from the JSON so its edges become dangling
        var raw  = try Data(contentsOf: url)
        var json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var nodes = json["nodes"] as! [[String: Any]]
        nodes.removeAll { ($0["title"] as? String) == "Remove" }
        json["nodes"] = nodes
        raw = try JSONSerialization.data(withJSONObject: json)
        try raw.write(to: url)

        let graph2       = ContextGraph()
        let persistence2 = ContextGraphPersistence(fileURL: url)
        persistence2.load(into: graph2)

        XCTAssertEqual(graph2.nodeCount, 1, "Only the surviving node should load")
        XCTAssertEqual(graph2.edgeCount, 0, "Dangling edge must be dropped")
    }

    // MARK: - Pruning

    func testPrune_removesStaleInferredNode() throws {
        let graph = ContextGraph()

        var enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601

        let staleNode = makeNode(type: .project, title: "Stale", trustTier: .inferred, confidence: 0.2)
        let staleID   = graph.upsertNode(staleNode)

        // Back-date updatedAt so the node qualifies as stale
        var raw  = try enc.encode(staleNode)
        var dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        dict["updatedAt"] = "2020-01-01T00:00:00Z"
        raw = try JSONSerialization.data(withJSONObject: dict)
        let backdated = try dec.decode(ContextNode.self, from: raw)
        graph.upsertNode(backdated)

        let policy = PrunePolicy(maxNodes: 1000, maxEdges: 1000,
                                 minConfidenceForInferred: 0.40,
                                 maxAgeForInferredDays: 30)
        let result = graph.prune(policy: policy)

        XCTAssertEqual(result.nodesRemoved, 1)
        XCTAssertNil(graph.node(for: staleID))
    }

    func testPrune_preservesHighTrustNode() {
        let graph     = ContextGraph()
        let trusted   = makeNode(title: "UserEdited", trustTier: .userEdited,
                                  confidence: 0.1, externalID: "trusted:001")
        let trustedID = graph.upsertNode(trusted)

        // maxNodes: 0 would normally evict everything, but only .inferred nodes are candidates
        let policy = PrunePolicy(maxNodes: 0, maxEdges: 0,
                                 minConfidenceForInferred: 0.99,
                                 maxAgeForInferredDays: 0)
        graph.prune(policy: policy)

        XCTAssertNotNil(graph.node(for: trustedID), "High-trust node must survive aggressive pruning")
    }

    func testPrune_edgeCap_dropsLowestConfidence() {
        let graph = ContextGraph()
        let a = graph.upsertNode(makeNode(title: "A"))
        let b = graph.upsertNode(makeNode(title: "B"))
        let c = graph.upsertNode(makeNode(title: "C"))

        graph.upsertEdge(ContextEdge(from: a, to: b, type: .relatesTo,   confidence: 0.9))
        graph.upsertEdge(ContextEdge(from: a, to: c, type: .sameTopicAs, confidence: 0.2))

        let policy = PrunePolicy(maxNodes: 1000, maxEdges: 1,
                                 minConfidenceForInferred: 0.0,
                                 maxAgeForInferredDays: 365)
        let result = graph.prune(policy: policy)

        XCTAssertEqual(result.edgesRemoved, 1)
        XCTAssertEqual(graph.edgeCount, 1)
        let remaining = graph.outgoingEdges(from: a)
        XCTAssertEqual(remaining.first?.to, b, "Low-confidence edge should be dropped first")
    }

    // MARK: - Duplicate edges merge

    func testEdgeDedup_mergesHigherConfidence() {
        let graph = ContextGraph()
        let a = graph.upsertNode(makeNode(title: "A"))
        let b = graph.upsertNode(makeNode(title: "B"))

        let e1ID = graph.upsertEdge(ContextEdge(from: a, to: b, type: .relatesTo, confidence: 0.4))
        let e2ID = graph.upsertEdge(ContextEdge(from: a, to: b, type: .relatesTo, confidence: 0.9))

        XCTAssertEqual(e1ID, e2ID, "Same (from, to, type) must reuse existing edge ID")
        XCTAssertEqual(graph.edgeCount, 1)
        XCTAssertEqual(graph.outgoingEdges(from: a).first?.confidence, 0.9)
    }

    // MARK: - Enrichment: thread↔memory cross-links

    func testEnrichCrossLinks_sharedKeywords_produceContinuityChain() {
        let index  = ProjectRelationshipIndex.shared
        let thread = makeTaskThread(title: "Building Jarvis assistant")
        let memory = makeMemoryCandidate(title: "Jarvis assistant design notes",
                                         summary: "Notes about the assistant architecture")

        index.getTaskThreads = { [thread] }
        index.getMemories    = { [memory] }
        index.refresh()

        let chain = index.activeContinuityChain(limit: 20)
        XCTAssertFalse(chain.isEmpty, "Continuity chain must not be empty after ingestion")
        let nodeTypes = Set(chain.map(\.type))
        XCTAssertTrue(nodeTypes.contains(.taskThread), "Thread node must appear in continuity chain")
    }

    // MARK: - Answer Composer: budget safety

    func testAnswerComposer_veryTightBudget_returnsNil() {
        let index  = ProjectRelationshipIndex.shared
        let memory = makeMemoryCandidate(title: "Some memory note with several words",
                                         summary: "Long summary that fills up budget space quickly")
        index.getMemories = { [memory] }
        index.refresh()

        let result = makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .projectReflection, charBudget: 5)
        XCTAssertNil(result, "Budget of 5 chars cannot fit even the header — must return nil")
    }

    func testAnswerComposer_noGraph_returnsNil() {
        XCTAssertNil(
            makeComposer(withGraph: false)
                .buildGraphContextBlock(route: .projectReflection)
        )
    }

    // MARK: - pbxproj: no duplicate build-file UUIDs

    func testNoDuplicateBuildFileUUIDs() throws {
        let pbxprojURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JarvisMac.xcodeproj/project.pbxproj")

        let content = try String(contentsOf: pbxprojURL, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"([A-F0-9]{24}) /\* .+? in Sources \*/"#)
        let ns      = content as NSString
        let matches = pattern.matches(in: content, range: NSRange(location: 0, length: ns.length))
        let uuids   = matches.map { ns.substring(with: $0.range(at: 1)) }
        let dupes   = Dictionary(grouping: uuids, by: { $0 }).filter { $1.count > 1 }.keys
        XCTAssertTrue(dupes.isEmpty, "Duplicate build-file UUIDs: \(dupes.sorted().joined(separator: ", "))")
    }
}
