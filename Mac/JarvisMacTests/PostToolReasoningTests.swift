import XCTest
@testable import JarvisMac

// MARK: - PostToolReasoningTests

/// Tests for the CHAT_PLUS_TOOL_PLUS_REASONING pipeline:
/// ToolExecutionGraph, PostToolContextInjection, VisionActionPipeline,
/// ConversationRoute/Router classification.
@MainActor
final class PostToolReasoningTests: XCTestCase {

    // MARK: - ToolExecutionGraph

    func testGraphRecordsStageResult() async {
        let graph = ToolExecutionGraph()
        let stages = [ToolExecutionGraph.Stage(kind: .captureFrame, timeoutSeconds: 2.0)]
        let result = await graph.execute(stages: stages, query: "test") { _ in "frame description" }
        XCTAssertEqual(result.stageResults[.captureFrame], "frame description")
        XCTAssertTrue(result.timedOutStages.isEmpty)
    }

    func testGraphTimesOutSlow() async {
        let graph = ToolExecutionGraph()
        let stages = [ToolExecutionGraph.Stage(kind: .captureFrame, timeoutSeconds: 0.05)]
        let result = await graph.execute(stages: stages, query: "test") { _ in
            try? await Task.sleep(for: .seconds(1.0))
            return "too late"
        }
        XCTAssertTrue(result.timedOutStages.contains(.captureFrame))
        XCTAssertNil(result.stageResults[.captureFrame])
    }

    func testGraphElapsedTimePositive() async {
        let graph = ToolExecutionGraph()
        let stages = [ToolExecutionGraph.Stage(kind: .runVisionSummary, timeoutSeconds: 1.0)]
        let result = await graph.execute(stages: stages, query: "q") { _ in "summary" }
        XCTAssertGreaterThan(result.elapsedMs, 0)
    }

    func testGraphCombinedContextFiltersControlSignals() async {
        let graph = ToolExecutionGraph()
        let stages = [
            ToolExecutionGraph.Stage(kind: .openCamera, timeoutSeconds: 1.0),
            ToolExecutionGraph.Stage(kind: .captureFrame, timeoutSeconds: 1.0),
        ]
        let result = await graph.execute(stages: stages, query: "q") { kind in
            switch kind {
            case .openCamera:    return "camera_opened"
            case .captureFrame:  return "person is sitting"
            default:             return nil
            }
        }
        let ctx = result.combinedContext
        XCTAssertTrue(ctx.contains("person is sitting"), "captureFrame result should be in combinedContext")
        XCTAssertFalse(ctx.contains("camera_opened"),   "openCamera control signal should be filtered")
    }

    func testGraphSucceededFlagRequiresNoTimeouts() async {
        let graph = ToolExecutionGraph()
        let stages = [ToolExecutionGraph.Stage(kind: .captureFrame, timeoutSeconds: 1.0)]
        let result = await graph.execute(stages: stages, query: "q") { _ in "desc" }
        XCTAssertTrue(result.succeeded)
    }

    // MARK: - PostToolContextInjection

    func testContextBlockIncludesQuery() async {
        let result = ToolExecutionGraph.GraphResult(
            graphID: UUID(), triggerQuery: "am I soaking",
            stageResults: [.captureFrame: "person is dripping wet"],
            timedOutStages: [], elapsedMs: 50
        )
        let block = PostToolContextInjection.shared.buildContextBlock(result)
        XCTAssertTrue(block.contains("am I soaking"))
        XCTAssertTrue(block.contains("person is dripping wet"))
    }

    func testEmptyResultFiresFallback() async {
        let injection = PostToolContextInjection()
        var fallbackCalled = false
        injection.onFallback = { _ in fallbackCalled = true }
        injection.onInjectAndReason = { _, _ in XCTFail("should not reason on empty result") }

        let result = ToolExecutionGraph.GraphResult(
            graphID: UUID(), triggerQuery: "q",
            stageResults: [:],
            timedOutStages: [.captureFrame],
            elapsedMs: 100
        )
        await injection.inject(result: result)
        XCTAssertTrue(fallbackCalled)
    }

    func testContextBlockFiltersNonContentStages() {
        let result = ToolExecutionGraph.GraphResult(
            graphID: UUID(), triggerQuery: "q",
            stageResults: [.openCamera: "opened", .waitForFrame: "ready", .captureFrame: "a cat"],
            timedOutStages: [], elapsedMs: 10
        )
        let block = PostToolContextInjection.shared.buildContextBlock(result)
        XCTAssertTrue(block.contains("a cat"))
        XCTAssertFalse(block.contains("opened"))
        XCTAssertFalse(block.contains("ready"))
    }

    // MARK: - VisionActionPipeline

    func testPipelineFallbackWhenNoCameraResult() async {
        let pipeline = VisionActionPipeline()
        pipeline.cameraWarmupSeconds = 0.01
        pipeline.captureTimeoutSeconds = 0.1

        var fallbackText = ""
        pipeline.onOpenCamera = {}
        pipeline.captureVisionSummary = { nil }
        pipeline.onFallback = { fallbackText = $0 }
        pipeline.onLLMReason = { _, _ in XCTFail("should not reason with no frame") }

        await pipeline.run(query: "tell me if I am soaking")
        XCTAssertFalse(fallbackText.isEmpty, "Should have fallback message")
    }

    func testPipelineCallsLLMReasonWithVisionContext() async {
        let pipeline = VisionActionPipeline()
        pipeline.cameraWarmupSeconds = 0.01
        pipeline.captureTimeoutSeconds = 1.0

        var reasonedContext = ""
        var reasonedQuery = ""
        pipeline.onOpenCamera = {}
        pipeline.captureVisionSummary = { "person appears completely soaked" }
        pipeline.onFallback = { _ in XCTFail("should not fall back") }
        pipeline.onLLMReason = { ctx, q in reasonedContext = ctx; reasonedQuery = q }

        await pipeline.run(query: "tell me if I am soaking")
        XCTAssertTrue(reasonedContext.contains("person appears completely soaked"))
        XCTAssertEqual(reasonedQuery, "tell me if I am soaking")
    }

    // MARK: - ConversationRoute

    func testChatPlusToolPlusReasoningShortCircuits() {
        let result = ConversationRouteResult(
            route: .chatPlusToolPlusReasoning,
            confidence: 0.88,
            commandHint: "camera",
            rationale: "test",
            fastPath: true
        )
        XCTAssertTrue(result.shouldShortCircuit)
    }

    // MARK: - ConversationRouter detection

    func testRouterDetectsCameraAndTellMe() {
        let router = ConversationRouter()
        let result = router.classifyFast("open the camera and tell me if i am soaking")
        XCTAssertEqual(result.route, .chatPlusToolPlusReasoning)
        XCTAssertEqual(result.commandHint, "camera")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.80)
    }

    func testRouterDetectsScreenshotAndExplain() {
        let router = ConversationRouter()
        let result = router.classifyFast("take a screenshot and explain what you see")
        XCTAssertEqual(result.route, .chatPlusToolPlusReasoning)
        XCTAssertEqual(result.commandHint, "screenshot")
    }

    // MARK: - pbxproj UUID regression

}
