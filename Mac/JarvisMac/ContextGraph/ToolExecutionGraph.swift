import Foundation
import os

// MARK: - ToolExecutionGraph

/// Models a multi-stage tool execution pipeline with per-stage timeouts,
/// result accumulation, and diagnostic tracking.
///
/// Used by VisionActionPipeline and PostToolContextInjection to orchestrate
/// the conversation→tool→reasoning→reply flow.
@MainActor
final class ToolExecutionGraph {

    static let shared = ToolExecutionGraph()

    private let log = Logger(subsystem: "com.jarvis", category: "tool_graph")

    // MARK: - Types

    enum StageKind: String, CaseIterable {
        case openCamera          = "open_camera"
        case waitForFrame        = "wait_for_frame"
        case captureFrame        = "capture_frame"
        case runVisionSummary    = "vision_summary"
        case ocrAnalysis         = "ocr_analysis"
        case screenshotAnalysis  = "screenshot_analysis"
        case diagnosticsAnalysis = "diagnostics_analysis"
        case browserInspection   = "browser_inspection"
        case regionUnderstanding = "region_understanding"
    }

    struct Stage {
        let kind: StageKind
        let timeoutSeconds: Double
    }

    struct GraphResult {
        let graphID: UUID
        let triggerQuery: String
        let stageResults: [StageKind: String]
        let timedOutStages: [StageKind]
        let elapsedMs: Double

        var succeeded: Bool { !stageResults.isEmpty && timedOutStages.isEmpty }

        // Combines all meaningful results into one LLM-injectable string.
        var combinedContext: String {
            let contentStages: Set<StageKind> = [
                .captureFrame, .runVisionSummary, .ocrAnalysis,
                .screenshotAnalysis, .diagnosticsAnalysis, .browserInspection, .regionUnderstanding
            ]
            let parts = stageResults
                .filter { contentStages.contains($0.key) }
                .map { "[\($0.key.rawValue.uppercased())]\n\($0.value)" }
            return parts.joined(separator: "\n\n")
        }
    }

    // MARK: - Diagnostics

    struct ExecutionDiagnostic {
        var graphID: UUID
        var toolStartedAt: Date
        var toolCompletedAt: Date?
        var reasoningStartedAt: Date?
        var reasoningCompletedAt: Date?
        var postToolResponseGenerated: Bool = false
        var timedOut: Bool = false
        var stagesCompleted: [StageKind] = []

        var toolLatencyMs: Double? {
            guard let c = toolCompletedAt else { return nil }
            return c.timeIntervalSince(toolStartedAt) * 1000
        }

        var totalLatencyMs: Double? {
            guard let c = reasoningCompletedAt else { return nil }
            return c.timeIntervalSince(toolStartedAt) * 1000
        }
    }

    // MARK: - State

    private(set) var recentDiagnostics: [ExecutionDiagnostic] = []
    private var activeDiagnostics: [UUID: ExecutionDiagnostic] = [:]

    // MARK: - Execution

    /// Runs stages sequentially. Each stage is given its timeout; if it exceeds
    /// the deadline the stage is marked timed-out and execution continues (except
    /// for critical capture stages where timeout aborts the graph).
    func execute(
        stages: [Stage],
        query: String,
        stageRunner: @escaping (StageKind) async -> String?
    ) async -> GraphResult {
        let id = UUID()
        let start = Date()
        var diagnostic = ExecutionDiagnostic(graphID: id, toolStartedAt: start)
        activeDiagnostics[id] = diagnostic

        var stageResults: [StageKind: String] = [:]
        var timedOut: [StageKind] = []

        log.debug("graph_start id=\(id.uuidString) query=\"\(query.prefix(60))\"")

        for stage in stages {
            log.debug("stage_start kind=\(stage.kind.rawValue)")

            let result = await withTaskGroup(of: String?.self) { group -> String? in
                group.addTask { await stageRunner(stage.kind) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(stage.timeoutSeconds))
                    return nil
                }
                var first: String? = nil
                for await value in group {
                    first = value
                    group.cancelAll()
                    break
                }
                return first
            }

            if let result, !result.isEmpty {
                stageResults[stage.kind] = result
                diagnostic.stagesCompleted.append(stage.kind)
                log.debug("stage_complete kind=\(stage.kind.rawValue)")
            } else {
                timedOut.append(stage.kind)
                diagnostic.timedOut = true
                log.warning("stage_timeout kind=\(stage.kind.rawValue)")
                // Abort early for critical content-producing stages
                if stage.kind == .captureFrame || stage.kind == .runVisionSummary {
                    break
                }
            }
        }

        diagnostic.toolCompletedAt = Date()
        let elapsed = Date().timeIntervalSince(start) * 1000
        let graphResult = GraphResult(
            graphID: id,
            triggerQuery: query,
            stageResults: stageResults,
            timedOutStages: timedOut,
            elapsedMs: elapsed
        )

        activeDiagnostics[id] = diagnostic
        storeDiagnostic(diagnostic)

        log.debug("graph_complete id=\(id.uuidString) done=\(stageResults.count) timed_out=\(timedOut.count) elapsed_ms=\(String(format: "%.0f", elapsed))")
        return graphResult
    }

    // MARK: - Reasoning lifecycle

    func markReasoningStarted(for graphID: UUID) {
        activeDiagnostics[graphID]?.reasoningStartedAt = Date()
        log.debug("reasoning_start id=\(graphID.uuidString)")
        LatencyBudgetSystem.shared.record(.silentActionDispatch, durationMs: 0)
    }

    func markReasoningComplete(for graphID: UUID, responseGenerated: Bool) {
        activeDiagnostics[graphID]?.reasoningCompletedAt = Date()
        activeDiagnostics[graphID]?.postToolResponseGenerated = responseGenerated
        if var d = activeDiagnostics.removeValue(forKey: graphID) {
            d.postToolResponseGenerated = responseGenerated
            storeDiagnostic(d)
            if let latency = d.totalLatencyMs {
                log.info("post_tool_complete id=\(graphID.uuidString) total_ms=\(String(format: "%.0f", latency)) response=\(responseGenerated)")
            }
        }
    }

    // MARK: - Diagnostics

    private func storeDiagnostic(_ d: ExecutionDiagnostic) {
        recentDiagnostics.append(d)
        if recentDiagnostics.count > 50 { recentDiagnostics.removeFirst() }
    }

    var diagnosticSummary: String {
        guard !recentDiagnostics.isEmpty else { return "No tool graphs executed" }
        return recentDiagnostics.suffix(5).map { d in
            let latency = d.totalLatencyMs.map { String(format: "%.0fms", $0) } ?? "pending"
            return "\(d.graphID.uuidString.prefix(8)) stages=\(d.stagesCompleted.count) timeout=\(d.timedOut) latency=\(latency) response=\(d.postToolResponseGenerated)"
        }.joined(separator: "\n")
    }
}
