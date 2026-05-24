import Foundation
import os

// MARK: - VisionActionPipeline

/// Orchestrates the camera-specific tool+reasoning pipeline:
///   open camera → wait for warmup → capture frame → vision summary → LLM reasoning → reply
///
/// Called when ConversationRouter detects `.chatPlusToolPlusReasoning` with a camera hint.
/// The pipeline runs entirely through ToolExecutionGraph so diagnostics and timeouts
/// are handled consistently with other tool types.
@MainActor
final class VisionActionPipeline {

    static let shared = VisionActionPipeline()

    private let log = Logger(subsystem: "com.jarvis", category: "vision_pipeline")

    // MARK: - Configuration

    var cameraWarmupSeconds: Double = 1.5
    var captureTimeoutSeconds: Double = 4.0
    var totalPipelineTimeoutSeconds: Double = 10.0

    // MARK: - Callbacks (wired by JarvisController)

    /// Opens the camera overlay so the user can see what Jarvis is looking at.
    var onOpenCamera: (() -> Void)?

    /// Performs an async frame capture and returns a vision description.
    /// Returns nil if the camera is unavailable or the capture fails.
    var captureVisionSummary: (() async -> String?)?

    /// Called with (contextBlock, originalQuery) to trigger LLM reasoning.
    /// Wired to JarvisController.speakWithToolContext().
    var onLLMReason: ((String, String) async -> Void)?

    /// Called when the pipeline cannot produce a result — provides a graceful fallback.
    var onFallback: ((String) -> Void)?

    // MARK: - Internal state (per-run)

    private var cachedFrameDescription: String? = nil

    // MARK: - Pipeline stages

    private var stages: [ToolExecutionGraph.Stage] {[
        ToolExecutionGraph.Stage(kind: .openCamera,       timeoutSeconds: 1.0),
        ToolExecutionGraph.Stage(kind: .waitForFrame,     timeoutSeconds: cameraWarmupSeconds + 0.5),
        ToolExecutionGraph.Stage(kind: .captureFrame,     timeoutSeconds: captureTimeoutSeconds),
        ToolExecutionGraph.Stage(kind: .runVisionSummary, timeoutSeconds: 1.0),
    ]}

    // MARK: - Run

    func run(query: String) async {
        log.debug("pipeline_start query=\"\(query.prefix(60))\"")
        cachedFrameDescription = nil

        let result = await ToolExecutionGraph.shared.execute(
            stages: stages,
            query: query
        ) { [weak self] stageKind in
            guard let self else { return nil }
            return await self.runStage(stageKind)
        }

        ToolExecutionGraph.shared.markReasoningStarted(for: result.graphID)

        let contextBlock = PostToolContextInjection.shared.buildContextBlock(result)

        if contextBlock.isEmpty || result.combinedContext.isEmpty {
            log.warning("pipeline_no_vision_result — using fallback")
            onFallback?("I tried to look but couldn't capture a clear frame. Make sure the camera is enabled and try again.")
            ToolExecutionGraph.shared.markReasoningComplete(for: result.graphID, responseGenerated: false)
            return
        }

        log.debug("pipeline_reasoning context_len=\(contextBlock.count)")
        await onLLMReason?(contextBlock, query)
        ToolExecutionGraph.shared.markReasoningComplete(for: result.graphID, responseGenerated: true)
    }

    // MARK: - Stage runners

    private func runStage(_ kind: ToolExecutionGraph.StageKind) async -> String? {
        switch kind {
        case .openCamera:
            onOpenCamera?()
            return "camera_opened"

        case .waitForFrame:
            // Give the camera feed a moment to stabilise before capturing.
            try? await Task.sleep(for: .seconds(cameraWarmupSeconds))
            return "frame_ready"

        case .captureFrame:
            let desc = await captureVisionSummary?()
            cachedFrameDescription = desc
            return desc

        case .runVisionSummary:
            // Return cached capture result so we don't call captureVisionSummary twice.
            if let cached = cachedFrameDescription { return cached }
            let fallback = await captureVisionSummary?()
            return fallback

        default:
            return nil
        }
    }
}

// MARK: - ScreenshotActionPipeline

/// Minimal screenshot + OCR pipeline for the tool+reasoning flow.
/// Extends ToolExecutionGraph with screen-capture stages.
@MainActor
final class ScreenshotActionPipeline {

    static let shared = ScreenshotActionPipeline()

    private let log = Logger(subsystem: "com.jarvis", category: "screenshot_pipeline")

    // MARK: - Callbacks

    var captureScreenshot: (() async -> String?)?
    var onLLMReason: ((String, String) async -> Void)?
    var onFallback: ((String) -> Void)?

    // MARK: - Run

    func run(query: String) async {
        log.debug("screenshot_pipeline_start query=\"\(query.prefix(60))\"")

        let stages: [ToolExecutionGraph.Stage] = [
            ToolExecutionGraph.Stage(kind: .screenshotAnalysis, timeoutSeconds: 5.0),
        ]

        let result = await ToolExecutionGraph.shared.execute(stages: stages, query: query) { [weak self] _ in
            await self?.captureScreenshot?()
        }

        ToolExecutionGraph.shared.markReasoningStarted(for: result.graphID)

        let contextBlock = PostToolContextInjection.shared.buildContextBlock(result)
        if contextBlock.isEmpty {
            onFallback?("I wasn't able to capture the screen content.")
            ToolExecutionGraph.shared.markReasoningComplete(for: result.graphID, responseGenerated: false)
            return
        }

        await onLLMReason?(contextBlock, query)
        ToolExecutionGraph.shared.markReasoningComplete(for: result.graphID, responseGenerated: true)
    }
}
