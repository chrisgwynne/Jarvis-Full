import Foundation

// MARK: - MemoryExtractor

/// Inspects conversation turns and produces `MemoryCandidate` values that
/// the caller can decide to persist in `MemoryStore`.
///
/// Extraction runs in two passes:
/// 1. **Rule-based (synchronous)** — pattern matches on the lowercased
///    transcript.  Fast and zero-cost when the LLM is unavailable.
/// 2. **LLM-assisted classification (async, optional)** — re-classifies
///    individual candidates when higher precision is needed.  The caller
///    decides whether to invoke this; `MemoryExtractor` never calls it
///    automatically.
///
/// **Usage**
/// ```swift
/// let candidates = await extractor.extract(
///     transcript: transcript,
///     route: route,
///     response: spokenResponse
/// )
/// // Filter by confidence, then store the keepers:
/// for c in candidates where c.confidence >= 0.75 {
///     memoryStore.save(c)
/// }
/// ```
@MainActor
final class MemoryExtractor {

    // MARK: - Dependencies

    /// Optional — when `nil` the LLM classification path is a no-op.
    private let llmRouter: LLMRouter?

    // MARK: - Init

    init(llmRouter: LLMRouter?) {
        self.llmRouter = llmRouter
    }

    // MARK: - Rule-Based Extraction

    /// Extract memory candidates from a single conversation turn.
    ///
    /// Multiple candidates may be returned (e.g. a transcript can contain
    /// both a project-progress mention and an idea).  Duplicates across
    /// turns are the caller's responsibility to deduplicate.
    ///
    /// - Parameters:
    ///   - transcript: The original user utterance.
    ///   - route: The `ConversationRoute` already assigned to this turn.
    ///   - response: Jarvis's spoken response, if any.  Currently unused but
    ///     available for future extraction of assistant-side commitments.
    ///   - date: Timestamp for the candidates (defaults to `Date()`).
    func extract(
        transcript: String,
        route: ConversationRoute,
        response: String?,
        date: Date = Date()
    ) async -> [MemoryCandidate] {

        var candidates: [MemoryCandidate] = []
        let t = transcript.lowercased()

        // ── Project progress ──────────────────────────────────────────────
        if route == .projectReflection {
            let keywords = ["built", "finished", "completed", "implemented",
                            "added", "fixed", "shipped", "released", "deployed"]
            if keywords.contains(where: { t.contains($0) }) {
                candidates.append(MemoryCandidate(
                    type: .projectProgress,
                    tier: .projectMemory,
                    title: "Progress: \(extractSubject(transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.80,
                    tags: ["project", "progress"],
                    createdAt: date
                ))
            }
        }

        // ── User preferences ──────────────────────────────────────────────
        let prefPhrases = [
            "i prefer", "i like", "i want", "i always",
            "i usually", "i hate", "i don't like",
        ]
        for phrase in prefPhrases {
            if t.contains(phrase) {
                candidates.append(MemoryCandidate(
                    type: .userPreference,
                    tier: .longTermUserPreference,
                    title: "Preference: \(extractAfter(phrase, in: transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.75,
                    tags: ["preference"],
                    createdAt: date
                ))
                break  // One preference candidate per turn is enough.
            }
        }

        // ── Architectural / implementation decisions ───────────────────────
        let decisionPhrases = [
            "decided", "decision is", "going with", "we'll use",
            "using", "chose", "choice is",
        ]
        if route == .projectReflection || route == .knowledgeQuery {
            for phrase in decisionPhrases {
                if t.contains(phrase) {
                    candidates.append(MemoryCandidate(
                        type: .projectDecision,
                        tier: .projectMemory,
                        title: "Decision: \(extractAfter(phrase, in: transcript))",
                        summary: cleanForMemory(transcript),
                        rawText: transcript,
                        confidence: 0.70,
                        tags: ["decision", "architecture"],
                        createdAt: date
                    ))
                    break
                }
            }
        }

        // ── Ideas ─────────────────────────────────────────────────────────
        let ideaPhrases = [
            "idea:", "idea is", "i think we should",
            "we could", "what if we", "maybe we should",
        ]
        for phrase in ideaPhrases {
            if t.contains(phrase) {
                candidates.append(MemoryCandidate(
                    type: .idea,
                    tier: .projectMemory,
                    title: "Idea: \(extractAfter(phrase, in: transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.65,
                    tags: ["idea"],
                    createdAt: date
                ))
                break
            }
        }

        // ── Bug reports ───────────────────────────────────────────────────
        let bugPhrases = [
            "crashes", "broken", "doesn't work", "not working",
            "bug:", "regression", "broke since",
        ]
        for phrase in bugPhrases {
            if t.contains(phrase) {
                candidates.append(MemoryCandidate(
                    type: .bugReport,
                    tier: .projectMemory,
                    title: "Bug: \(extractSubject(transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.72,
                    tags: ["bug"],
                    createdAt: date
                ))
                break
            }
        }

        // ── Roadmap changes ───────────────────────────────────────────────
        let roadmapPhrases = [
            "add to roadmap", "add that to the roadmap", "save to roadmap",
            "remove from roadmap", "remove that from the roadmap",
            "add to sprint", "remove from sprint", "move to backlog",
        ]
        for phrase in roadmapPhrases {
            if t.contains(phrase) {
                candidates.append(MemoryCandidate(
                    type: .roadmapChange,
                    tier: .projectMemory,
                    title: "Roadmap change: \(extractAfter(phrase, in: transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.85,
                    tags: ["roadmap"],
                    createdAt: date
                ))
                break
            }
        }

        // ── Personal facts ────────────────────────────────────────────────
        let personalPhrases = [
            "i'm based in", "i live in", "i work at", "i work from",
            "my timezone", "i wake up", "i usually work",
        ]
        for phrase in personalPhrases {
            if t.contains(phrase) {
                candidates.append(MemoryCandidate(
                    type: .personalFact,
                    tier: .longTermUserPreference,
                    title: "Personal: \(extractAfter(phrase, in: transcript))",
                    summary: cleanForMemory(transcript),
                    rawText: transcript,
                    confidence: 0.78,
                    tags: ["personal"],
                    createdAt: date
                ))
                break
            }
        }

        return candidates
    }

    // MARK: - LLM-Assisted Classification

    /// Re-classifies a piece of text into a `MemoryCandidateType` using
    /// the LLM for higher precision.
    ///
    /// Returns `.temporaryNote` when the LLM is unavailable, the call
    /// fails, or the response doesn't match a known category.
    ///
    /// - Parameter text: The text to classify (typically `rawText` from
    ///   a `MemoryCandidate` produced by `extract(...)`).
    func classifyWithLLM(_ text: String) async -> MemoryCandidateType {
        guard let llm = llmRouter else { return .temporaryNote }

        let prompt = """
        Classify this statement into one category. Reply with ONE WORD only.

        Categories: USER_PREFERENCE, PROJECT_DECISION, PROJECT_PROGRESS, ROADMAP_CHANGE, BUG_REPORT, IDEA, PERSONAL_FACT, TEMPORARY_NOTE, DISCARD

        Rules:
        - USER_PREFERENCE: stable preference expressed by the user ("I prefer X", "I like short answers")
        - PROJECT_DECISION: architectural or implementation decision ("we'll use SQLite", "chose Apple Vision")
        - PROJECT_PROGRESS: user reporting completed work ("I built the tracking layer", "just shipped login")
        - ROADMAP_CHANGE: change to planned work ("remove that from the roadmap", "add X to sprint")
        - BUG_REPORT: reporting a bug or issue ("the timer crashes", "broken since yesterday")
        - IDEA: future improvement ("we could add X", "what if Y")
        - PERSONAL_FACT: personal info about the user ("I'm in London", "I work at night")
        - TEMPORARY_NOTE: short-lived context unlikely to matter tomorrow
        - DISCARD: random chat with no lasting value

        Statement: "\(text.prefix(300))"

        Category:
        """
        let req = LLMRequest(
            systemPrompt: "Classify statements into memory categories. Reply with one word only.",
            userPrompt: prompt,
            contextSummary: nil,
            temperature: 0.0,
            maxTokens: 5,
            responseFormat: .text,
            timeoutSeconds: 5
        )
        guard let response = try? await llm.complete(req) else { return .temporaryNote }

        let word = response.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch word {
        case "USER_PREFERENCE":   return .userPreference
        case "PROJECT_DECISION":  return .projectDecision
        case "PROJECT_PROGRESS":  return .projectProgress
        case "ROADMAP_CHANGE":    return .roadmapChange
        case "BUG_REPORT":        return .bugReport
        case "IDEA":              return .idea
        case "PERSONAL_FACT":     return .personalFact
        case "TEMPORARY_NOTE":    return .temporaryNote
        default:                  return .discard
        }
    }

    // MARK: - Private Helpers

    /// Returns the first 60 characters of the transcript as a subject line.
    private func extractSubject(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(60))
    }

    /// Returns the text that follows `phrase` in `text`, up to 60 chars.
    /// Falls back to the first 50 characters of `text` when `phrase` is absent.
    private func extractAfter(_ phrase: String, in text: String) -> String {
        let lowered = text.lowercased()
        guard let range = lowered.range(of: phrase) else {
            return String(text.prefix(50))
        }
        let after = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return String(after.prefix(60))
    }

    /// Trims whitespace from the transcript before storing as `summary`.
    private func cleanForMemory(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
