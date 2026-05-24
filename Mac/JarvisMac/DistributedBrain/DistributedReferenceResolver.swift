import Foundation

// MARK: - DistributedReferenceResolver

/// Resolves cross-device references — "that PR", "what I was looking at on Windows",
/// "the thing you just mentioned" — by first checking the EntityMemoryGraph, then
/// falling back to real-time presence snapshots from all surfaces.
@MainActor
final class DistributedReferenceResolver {

    static let shared = DistributedReferenceResolver()

    // Injected by JarvisController during bootstrap.
    weak var conversation: DistributedConversationCoordinator?
    weak var presence: GlobalPresenceAggregator?

    // MARK: - Resolve

    /// Attempts to resolve a reference phrase and returns augmented context text,
    /// or nil if the reference cannot be resolved.
    func resolve(_ phrase: String) -> String? {
        let normalized = phrase.lowercased()

        // ── Tier 1: Entity-memory graph ──────────────────────────────────────
        if let entityResolved = entityResolve(normalized) {
            return entityResolved
        }

        // ── Tier 2: Presence heuristics (original behaviour) ─────────────────

        // "that page" / "that site" / "the browser" → Windows browser URL
        if containsAny(normalized, ["that page", "that site", "the page", "in browser", "on browser",
                                     "the website", "that link", "that url"]) {
            if let url = presence?.windowsPresence?.browserURL, !url.isEmpty {
                return "browser URL on Windows: \(url)"
            }
        }

        // "that PR" / "that issue" / "that ticket" → Windows foreground title
        if containsAny(normalized, ["that pr", "that issue", "that ticket", "that bug", "the pr",
                                     "that commit", "the issue", "the ticket"]) {
            if let title = presence?.windowsPresence?.foregroundWindowTitle, !title.isEmpty {
                return "Windows window: \(title)"
            }
        }

        // "that file" / "that code" / "what I was editing" → active coding file
        if containsAny(normalized, ["that file", "that code", "what i was editing",
                                     "the file", "the code", "what you saw"]) {
            if let file = presence?.windowsPresence?.activeCodingFile, !file.isEmpty {
                return "Windows active file: \(file)"
            }
        }

        // "what I was doing on Windows" → full context oneliner
        if containsAny(normalized, ["on windows", "from windows", "what i was doing",
                                     "what was on my screen", "from the other device"]) {
            if let snap = presence?.windowsPresence {
                return "Windows context: \(snap.contextOneLiner)"
            }
        }

        // "what you said earlier" / "the thing from before" → last assistant frame
        if containsAny(normalized, ["you said", "you mentioned", "earlier you", "from before",
                                     "the thing you said", "last response"]) {
            if let frame = conversation?.frames.last(where: { $0.role == .assistant }) {
                return "Earlier: \(frame.transcript)"
            }
        }

        // "what I said" / "my last message" → last user frame
        if containsAny(normalized, ["what i said", "my last message", "i said", "i asked"]) {
            if let frame = conversation?.frames.last(where: { $0.role == .user }) {
                return "User said: \(frame.transcript)"
            }
        }

        return nil
    }

    /// Enriches an LLM prompt with any resolvable references found in the transcript.
    func enrichedContext(for transcript: String) -> String? {
        let normalized = transcript.lowercased()
        let signals = ["that", "this", "it", "the thing", "on windows", "earlier", "before",
                       "what i", "what you", "from the", "the other", "continue", "again"]
        guard signals.contains(where: { normalized.contains($0) }) else { return nil }

        if let resolved = resolve(transcript) {
            return "[REFERENCE RESOLUTION]\n\(resolved)"
        }
        return nil
    }

    // MARK: - Entity-memory resolution (Tier 1)

    private func entityResolve(_ normalized: String) -> String? {
        let graph = EntityMemoryGraph.shared
        let extractor = ConversationEntityExtractor.shared

        // Pronoun → most salient entity
        if let ref = extractor.detectReferencePhrase(in: normalized) {
            switch ref.kind {
            case .pronoun:
                if let top = HybridEntityMatcher.mostSalient(in: graph) {
                    EntitySalienceEngine.shared.boost(id: top.id)
                    EntityMemoryDiagnostics.shared.recordResolution(ResolutionResult(
                        entity: top, confidence: 0.75, source: "salience",
                        candidates: [top], needsClarification: false, clarificationPrompt: nil))
                    return "[ENTITY] \(EntityContextBlockBuilder.buildReferenceLine(for: top))"
                }

            case .recency:
                // "the other PR" / "the other issue" etc.
                let kind = kindHint(from: normalized)
                let candidates = kind != nil ? graph.byKind(kind!, limit: 3) : graph.topSalient(limit: 3)
                if candidates.count >= 2 {
                    let other = candidates[1]
                    EntitySalienceEngine.shared.boost(id: other.id)
                    EntityMemoryDiagnostics.shared.recordResolution(ResolutionResult(
                        entity: other, confidence: 0.80, source: "recency",
                        candidates: candidates, needsClarification: false, clarificationPrompt: nil))
                    return "[ENTITY] \(EntityContextBlockBuilder.buildReferenceLine(for: other))"
                }

            case .crossDevice:
                let result = DistributedEntityLinker.shared.resolveWithDeviceBias(
                    phrase: normalized, deviceId: "windows")
                if let entity = result.entity {
                    EntityMemoryDiagnostics.shared.recordResolution(result)
                    return "[ENTITY] \(EntityContextBlockBuilder.buildReferenceLine(for: entity))"
                }

            case .continual:
                if let continuation = WorkflowContextResolver.resolveWorkflowContinuation() {
                    EntitySalienceEngine.shared.boost(id: continuation.id)
                    return "[ENTITY] continuing: \(EntityContextBlockBuilder.buildReferenceLine(for: continuation))"
                }

            case .deictic:
                let kind = kindHint(from: normalized)
                if let match = kind != nil
                    ? HybridEntityMatcher.mostRecentOf(kind: kind!, in: graph)
                    : HybridEntityMatcher.mostSalient(in: graph) {
                    EntitySalienceEngine.shared.boost(id: match.id)
                    EntityMemoryDiagnostics.shared.recordResolution(ResolutionResult(
                        entity: match, confidence: 0.70, source: "deictic",
                        candidates: [match], needsClarification: false, clarificationPrompt: nil))
                    return "[ENTITY] \(EntityContextBlockBuilder.buildReferenceLine(for: match))"
                }
            }
        }

        // Fuzzy entity name match
        let result = HybridEntityMatcher.bestMatch(phrase: normalized, in: graph)
        if let entity = result.entity, result.confidence >= 0.72 {
            EntitySalienceEngine.shared.boost(id: entity.id)
            EntityMemoryDiagnostics.shared.recordResolution(result)
            return "[ENTITY] \(EntityContextBlockBuilder.buildReferenceLine(for: entity))"
        }

        return nil
    }

    // MARK: - Private helpers

    private func kindHint(from text: String) -> EntityMemKind? {
        if text.contains("pr") || text.contains("pull request") { return .pullRequest }
        if text.contains("issue") || text.contains("bug")        { return .githubIssue }
        if text.contains("file") || text.contains("code")        { return .file }
        if text.contains("tab") || text.contains("page")         { return .browserTab }
        if text.contains("branch")                               { return .branch }
        if text.contains("task")                                  { return .task }
        return nil
    }

    private func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}
