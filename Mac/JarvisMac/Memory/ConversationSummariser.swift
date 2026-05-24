import Foundation
import os

/// Compresses raw conversation turns into concise long-term memory entries.
///
/// Run after each session ends (triggered by JarvisController when the phase
/// returns to .wakeListening after a conversation) or daily at startup.
/// Stores summaries as MemoryStore entries tagged "conversation_summary,auto".
@MainActor
final class ConversationSummariser {

    private let convStore: ConversationStore
    private let memStore: MemoryStore
    private let llmRouter: LLMRouter
    private let log = Logger(subsystem: "com.jarvis", category: "summariser")

    /// Minimum turns before summarisation is worthwhile.
    private let minTurns = 4
    /// How many recent turns to include in one summary batch.
    private let batchSize = 20
    /// Avoid re-summarising a session that was already summarised.
    private var lastSummarisedSessionId: String?

    init(convStore: ConversationStore, memStore: MemoryStore, llmRouter: LLMRouter) {
        self.convStore = convStore
        self.memStore = memStore
        self.llmRouter = llmRouter
    }

    // MARK: - Public API

    /// Summarise the most recent conversation turns if they haven't been
    /// summarised yet. Safe to call frequently — it's a no-op if already done.
    func summariseRecentIfNeeded(sessionId: String? = nil) async {
        // Check if we already summarised this session
        if let sid = sessionId, sid == lastSummarisedSessionId { return }

        // No-op if LLM is disabled
        guard llmRouter.mode != .disabled else {
            log.info("summarisationSkippedNoProvider — LLM router disabled")
            return
        }

        // No-op if no provider is reachable (avoids a doomed round-trip)
        guard await llmRouter.isAnyEnabled() else {
            log.info("summarisationSkippedNoProvider — no provider enabled/configured")
            return
        }

        let turns = await convStore.recent(limit: batchSize)
        guard turns.count >= minTurns else { return }

        let formatted = turns.map { t -> String in
            let role = t.role == "user" ? "User" : "Jarvis"
            return "\(role): \(t.text)"
        }.joined(separator: "\n")

        let prompt = """
        Summarise this conversation in 2-3 sentences. Extract any important facts, preferences, decisions, or action items. Be concise.

        \(formatted)

        Summary:
        """

        let summary = await callLLM(prompt: prompt)
        guard let summary else {
            // callLLM already logged the specific failure reason
            return
        }
        guard !summary.isEmpty else {
            log.info("summarisationFailedSafely — LLM returned empty text")
            return
        }

        memStore.remember(summary, tags: "conversation_summary,auto")
        lastSummarisedSessionId = sessionId
        log.info("Summarised conversation: \(summary.safePreview(80))")
    }

    // MARK: - Internal LLM call

    /// Calls the LLM router and returns the trimmed summary, or nil on any failure.
    /// Logs a specific marker so every failure path is identifiable in diagnostics.
    private func callLLM(prompt: String) async -> String? {
        let request = LLMRequest(
            systemPrompt: "You are a memory assistant. Extract key facts and summarise concisely.",
            userPrompt: prompt,
            temperature: 0.2,
            maxTokens: 200,
            timeoutSeconds: 15
        )
        do {
            let response = try await llmRouter.complete(request)
            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                log.info("summarisationFallbackUsed — provider=\(response.providerID, privacy: .public)")
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch let err as LLMError {
            // Distinguish "no provider available" from "provider error" for diagnostics.
            switch err {
            case .providerDisabled(let reason):
                log.info("summarisationSkippedNoProvider — \(reason, privacy: .public)")
            case .notConfigured(let reason):
                log.info("summarisationSkippedNoProvider — notConfigured: \(reason, privacy: .public)")
            default:
                log.warning("summarisationProviderUnavailable — \(err.errorDescription ?? "unknown", privacy: .public)")
            }
            return nil
        } catch {
            log.warning("summarisationFailedSafely — unexpected error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Daily startup: summarise any un-summarised turns from the last 24 hours.
    func dailySummarise() async {
        let dateKey = ISO8601DateFormatter().string(from: Date()).prefix(10) // yyyy-MM-dd
        await summariseRecentIfNeeded(sessionId: "daily_\(dateKey)")
    }
}
