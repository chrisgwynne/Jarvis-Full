import Foundation
import os

// MARK: - PostToolContextInjection

/// Formats ToolExecutionGraph results into LLM-injectable context blocks
/// and routes them back into the conversational reasoning pipeline.
///
/// Sits between ToolExecutionGraph and LLMFallbackHandler:
///   ToolExecutionGraph → PostToolContextInjection → LLMFallbackHandler → speak()
@MainActor
final class PostToolContextInjection {

    static let shared = PostToolContextInjection()

    private let log = Logger(subsystem: "com.jarvis", category: "post_tool")

    // MARK: - Callbacks (wired by JarvisController)

    /// Called with (contextBlock, originalQuery) to trigger LLM reasoning.
    var onInjectAndReason: ((String, String) async -> Void)?

    /// Called when the tool result is empty or timed out — provides a graceful fallback.
    var onFallback: ((String) -> Void)?

    // MARK: - Injection

    func inject(result: ToolExecutionGraph.GraphResult) async {
        guard !result.stageResults.isEmpty else {
            let fallback: String
            if !result.timedOutStages.isEmpty {
                let names = result.timedOutStages.map(\.rawValue).joined(separator: ", ")
                fallback = "I ran into a timeout during \(names). Try again in a moment."
            } else {
                fallback = "I wasn't able to get a result from that."
            }
            log.warning("inject_fallback query=\"\(result.triggerQuery.prefix(40))\"")
            onFallback?(fallback)
            return
        }

        let contextBlock = buildContextBlock(result)
        log.debug("inject_reason context_len=\(contextBlock.count) query=\"\(result.triggerQuery.prefix(40))\"")
        await onInjectAndReason?(contextBlock, result.triggerQuery)
    }

    // MARK: - Context Formatting

    func buildContextBlock(_ result: ToolExecutionGraph.GraphResult) -> String {
        // Only meaningful content stages are included in the LLM context.
        let contentStages: Set<ToolExecutionGraph.StageKind> = [
            .captureFrame, .runVisionSummary, .ocrAnalysis,
            .screenshotAnalysis, .diagnosticsAnalysis, .browserInspection, .regionUnderstanding
        ]
        let meaningful = result.stageResults.filter { contentStages.contains($0.key) }

        var lines: [String] = [
            "[TOOL RESULT — Use this to answer the user's question conversationally]",
            "User asked: \(result.triggerQuery)",
            "",
        ]

        for (kind, value) in meaningful {
            switch kind {
            case .captureFrame, .runVisionSummary:
                lines.append("Visual observation: \(value)")
            case .ocrAnalysis:
                lines.append("Text detected on screen: \(value)")
            case .screenshotAnalysis:
                lines.append("Screen content: \(value)")
            case .diagnosticsAnalysis:
                lines.append("Diagnostics: \(value)")
            case .browserInspection:
                lines.append("Browser content: \(value)")
            case .regionUnderstanding:
                lines.append("Region analysis: \(value)")
            default:
                break
            }
        }

        lines.append("")
        lines.append("Answer the user's question directly and conversationally using the above. Do not describe the tool — just answer.")

        if !result.timedOutStages.isEmpty {
            lines.append("Note: some stages timed out (\(result.timedOutStages.map(\.rawValue).joined(separator: ", "))), so the answer may be partial.")
        }

        return lines.joined(separator: "\n")
    }
}
