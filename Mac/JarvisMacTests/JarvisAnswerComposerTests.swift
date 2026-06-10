import XCTest
@testable import JarvisMac

@MainActor
final class JarvisAnswerComposerTests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() -> LLMRouter {
        LLMRouter(
            xai:      XAIProvider(baseURL: { "" }, modelName: { "" },
                                   enabled: { false }, apiKey: { nil }),
            miniMax:  MiniMaxProvider(baseURL: { "" }, modelName: { "" },
                                      enabled: { false }, apiKey: { nil }),
            gemini:   GeminiProvider(baseURL: { "" }, modelName: { "" },
                                     visionModel: { "" }, enabled: { false }, apiKey: { nil }),
            local: LlamaCppProvider(baseURL: { "" }, modelName: { "" }, enabled: { false })
        )
    }

    private func makeComposer(withGraph: Bool = false) -> JarvisAnswerComposer {
        JarvisAnswerComposer(
            llmRouter:      makeRouter(),
            contextBuilder: PersonalityContextBuilder(store: PersonalityFileStore()),
            activeContext:  ActiveContextRegistry.shared,
            graphIndex:     withGraph ? ProjectRelationshipIndex.shared : nil
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        ContextGraph.shared.reset()
    }

    override func tearDown() async throws {
        ContextGraph.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Graph block: inclusion rules

    func testGraphBlock_nil_whenGraphIndexNotInjected() {
        let composer = makeComposer(withGraph: false)
        XCTAssertNil(composer.buildGraphContextBlock(route: .projectReflection))
        XCTAssertNil(composer.buildGraphContextBlock(route: .knowledgeQuery))
    }

    func testGraphBlock_nil_forIrrelevantRoutes() {
        // Seed one task thread so the graph is non-empty
        let thread = ContextNode(type: .taskThread, title: "Sprint T", summary: "Active work",
                                  source: .taskThread, confidence: 0.9, trustTier: .system,
                                  externalID: "jac-test:thread:01")
        ContextGraph.shared.upsertNode(thread)

        let composer = makeComposer(withGraph: true)

        let irrelevantRoutes: [ConversationRoute] = [.generalChat, .command,
                                                      .memoryUpdate, .ignore, .clarification]
        for route in irrelevantRoutes {
            XCTAssertNil(composer.buildGraphContextBlock(route: route),
                         "Expected nil for route.\(route.rawValue) — graph should not fire")
        }
    }

    func testGraphBlock_nonNil_forProjectReflection_whenPopulated() {
        let thread = ContextNode(type: .taskThread, title: "Jarvis Sprint T",
                                  summary: "Building answer composer integration",
                                  source: .taskThread, confidence: 0.95, trustTier: .system,
                                  externalID: "jac-test:thread:02")
        ContextGraph.shared.upsertNode(thread)

        let composer = makeComposer(withGraph: true)
        let block = composer.buildGraphContextBlock(route: .projectReflection)

        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("[ACTIVE CONTEXT GRAPH") == true,
                      "Block should carry trust-tier label header")
        XCTAssertTrue(block?.contains("Jarvis Sprint T") == true,
                      "Block should contain the task thread title")
    }

    func testGraphBlock_nonNil_forKnowledgeQuery_whenPopulated() {
        let thread = ContextNode(type: .taskThread, title: "KQ Thread",
                                  summary: "Knowledge query test",
                                  source: .taskThread, confidence: 0.8, trustTier: .system,
                                  externalID: "jac-test:thread:kq")
        ContextGraph.shared.upsertNode(thread)

        let block = makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .knowledgeQuery)

        XCTAssertNotNil(block)
    }

    func testGraphBlock_nil_whenGraphIsEmpty() {
        // No nodes seeded — chain is empty, so nil expected
        XCTAssertNil(makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .projectReflection))
    }

    // MARK: - Graph block: budget enforcement

    func testGraphBlock_respectsCharBudget() {
        // Seed an anchor thread + many high-content neighbours so BFS would
        // overshoot without budget clamping.
        let thread = ContextNode(type: .taskThread, title: "Budget Thread",
                                  summary: "anchor",
                                  source: .taskThread, confidence: 0.9, trustTier: .system,
                                  externalID: "jac-test:thread:budget")
        let threadID = ContextGraph.shared.upsertNode(thread)

        for i in 0..<8 {
            let mem = ContextNode(type: .memory, title: "Memory \(i)",
                                   summary: String(repeating: "m", count: 200),
                                   source: .conversationMemory, confidence: 0.85,
                                   trustTier: .userEdited,
                                   externalID: "jac-test:mem:\(i)")
            let memID = ContextGraph.shared.upsertNode(mem)
            ContextGraph.shared.upsertEdge(
                ContextEdge(from: threadID, to: memID, type: .relatesTo, evidence: "test")
            )
        }

        let budget = 200
        let block = makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .projectReflection, charBudget: budget)

        if let block {
            // Sum all data lines (everything after the header) — must fit in budget.
            let dataChars = block
                .components(separatedBy: "\n")
                .dropFirst()
                .filter { !$0.isEmpty }
                .map(\.count)
                .reduce(0, +)
            XCTAssertLessThanOrEqual(dataChars, budget,
                                      "Data lines exceeded charBudget of \(budget)")
        }
        // If block is nil (budget too small for even one line), that's also correct.
    }

    func testGraphBlock_veryTightBudget_returnsNilOrSingleLine() {
        let thread = ContextNode(type: .taskThread, title: "T", summary: "S",
                                  source: .taskThread, confidence: 0.9, trustTier: .system,
                                  externalID: "jac-test:thread:tight")
        ContextGraph.shared.upsertNode(thread)

        // Budget of 1 — no line can fit; should return nil
        let block = makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .projectReflection, charBudget: 1)
        XCTAssertNil(block, "A budget of 1 char cannot fit any content line")
    }

    // MARK: - Trust-tier label

    func testGraphBlock_containsTrustTierLabel() {
        let thread = ContextNode(type: .taskThread, title: "Trust Check", summary: "test tier",
                                  source: .taskThread, confidence: 0.9, trustTier: .system,
                                  externalID: "jac-test:thread:trust")
        ContextGraph.shared.upsertNode(thread)

        let block = makeComposer(withGraph: true)
            .buildGraphContextBlock(route: .projectReflection)

        XCTAssertTrue(block?.contains("system") == true,
                      "Block data lines should include TrustTier.system label")
    }

    // MARK: - Existing composition path unbroken

    func testCompose_fallback_withNilGraphIndex_returnsNonNilForProjectReflection() async {
        let composer = makeComposer(withGraph: false)  // no graph
        let ctx = KnowledgeContext(
            projectFacts:    ["The app has 80 voice commands."],
            roadmapItems:    [],
            recentDecisions: [],
            memoryHits:      [],
            obsidianExcerpts: [],
            sources:         [],
            retrievalLatencyMs: 0
        )
        // LLM is disabled → falls back to knowledgeBasedFallback
        let result = await composer.compose(
            transcript: "what should I work on next?",
            route: .projectReflection,
            knowledgeContext: ctx,
            recentChatHistory: nil,
            userName: "Chris"
        )
        XCTAssertNotNil(result, "knowledge-based fallback should return a response")
    }

    func testCompose_fallback_knowledgeQuery_withMemoryHit() async {
        let composer = makeComposer(withGraph: false)
        let ctx = KnowledgeContext(
            projectFacts: [], roadmapItems: [], recentDecisions: [],
            memoryHits: ["We use SQLite with GRDB for persistence."],
            obsidianExcerpts: [],
            sources: [],
            retrievalLatencyMs: 0
        )
        let result = await composer.compose(
            transcript: "how do we persist data?",
            route: .knowledgeQuery,
            knowledgeContext: ctx,
            recentChatHistory: nil,
            userName: nil
        )
        XCTAssertNotNil(result)
    }

    func testCompose_fallback_memoryUpdate_returnsConfirmation() async {
        let result = await makeComposer(withGraph: false).compose(
            transcript: "remember that I prefer dark mode",
            route: .memoryUpdate,
            knowledgeContext: .empty,
            recentChatHistory: nil,
            userName: nil
        )
        XCTAssertNotNil(result)
    }

    // MARK: - No duplicate build file UUIDs

}
