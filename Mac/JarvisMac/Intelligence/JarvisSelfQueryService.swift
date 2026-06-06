import Foundation

// MARK: - JarvisSelfQueryService

/// Answers questions about Jarvis itself using grounded knowledge.
///
/// Combines ProjectKnowledgeGraph + CodebaseIndexer to produce answers
/// that explicitly state uncertainty. NEVER invents implementation status.
@MainActor
final class JarvisSelfQueryService {
    static let shared = JarvisSelfQueryService()

    var knowledgeGraph: ProjectKnowledgeGraph = .shared
    var indexer: CodebaseIndexer = .shared

    // MARK: - Detection

    private static let selfQuerySignals: [String] = [
        // Specific enough to indicate the user is asking about Jarvis's own
        // capabilities or state. Deliberately excludes broad conversational
        // openers ("can you", "do you", "are you", "what do you", etc.) that
        // would match entirely unrelated queries like "what do you think of Arne Slot".
        "are you able", "do you support", "are you connected",
        "do you have", "can jarvis", "does jarvis", "what can you",
        "what are you capable", "do you know how to", "can you do",
        "how are you built", "what features", "what integrations",
        "what services", "what is your", "how does your",
        "tell me about your", "explain your", "show me your",
        "jarvis status", "jarvis health", "your capabilities",
        "your features", "your integrations"
    ]

    /// Returns true if this query is asking about Jarvis's own capabilities or state.
    func isAboutSelf(_ normalized: String) -> Bool {
        Self.selfQuerySignals.contains(where: { normalized.contains($0) })
    }

    // MARK: - Query

    func query(
        userQuery: String,
        activeTopic: String? = nil
    ) async -> SelfQueryResult? {
        let normalized = userQuery.lowercased()

        // Find matching features
        let matchingFeatures = knowledgeGraph.features(matching: normalized)

        // Find relevant code chunks
        let chunks = indexer.search(query: normalized, limit: 4)

        // If we found nothing, return nil so the LLM handles it
        guard !matchingFeatures.isEmpty || !chunks.isEmpty else { return nil }

        // Determine dominant status
        let dominantStatus = matchingFeatures.first?.status

        let answer = buildGroundedAnswer(
            query: userQuery,
            features: matchingFeatures,
            chunks: chunks,
            activeTopic: activeTopic
        )

        let sources = Array(Set(
            matchingFeatures.flatMap { $0.files } +
            chunks.map { $0.displayPath }
        )).prefix(6).map { $0 }

        let confidence = dominantStatus.map { $0.confidence } ?? 0.4

        return SelfQueryResult(
            query: userQuery,
            relevantFeatures: matchingFeatures,
            relevantChunks: chunks,
            implementationState: dominantStatus,
            suggestedAnswer: answer,
            confidence: confidence,
            sources: sources
        )
    }

    // MARK: - Answer Builder

    /// Builds a grounded answer that explicitly states uncertainty where appropriate.
    private func buildGroundedAnswer(
        query: String,
        features: [FeatureNode],
        chunks: [CodeChunk],
        activeTopic: String?
    ) -> String {
        var parts: [String] = []

        for feature in features.prefix(3) {
            switch feature.status {
            case .implemented:
                parts.append("\(feature.name) is available. \(feature.summary)")

            case .partial:
                let issues = feature.knownIssues.prefix(1).joined(separator: "; ")
                let detail = issues.isEmpty ? "" : " (known gap: \(issues))"
                parts.append("\(feature.name) is partially implemented.\(detail) \(feature.summary)")

            case .stubbed:
                parts.append("\(feature.name) is stubbed — the structure exists but it's not fully functional yet.")

            case .broken:
                let issue = feature.knownIssues.first ?? "see known issues"
                parts.append("\(feature.name) exists but is currently broken: \(issue)")

            case .planned:
                parts.append("\(feature.name) is planned but hasn't been built yet.")

            case .unknown:
                parts.append("I can see \(feature.name) in the codebase but I'm not certain of its current state.")
            }
        }

        if parts.isEmpty, !chunks.isEmpty {
            // Fallback: describe what the chunks suggest
            let fileNames = chunks.prefix(2).map { $0.displayPath }.joined(separator: " and ")
            parts.append("There's code related to that in \(fileNames), but I'm not certain of its exact state.")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Context Block for LLM Injection

    /// Returns a compact context block to inject before the LLM call for self-queries.
    func contextBlock(for result: SelfQueryResult) -> String {
        guard !result.isEmpty else { return "" }
        var lines: [String] = ["[JARVIS SELF-KNOWLEDGE]"]

        for feature in result.relevantFeatures.prefix(3) {
            lines.append("• \(feature.name) [\(feature.status.humanLabel)]: \(feature.summary)")
            if !feature.knownIssues.isEmpty {
                lines.append("  Known issues: \(feature.knownIssues.prefix(2).joined(separator: "; "))")
            }
        }

        if !result.relevantChunks.isEmpty {
            lines.append("Relevant files: \(result.relevantChunks.prefix(3).map { $0.displayPath }.joined(separator: ", "))")
        }

        lines.append("Confidence: \(Int(result.confidence * 100))%")
        lines.append("DO NOT invent details not listed above. If uncertain, say so.")
        return lines.joined(separator: "\n")
    }
}
