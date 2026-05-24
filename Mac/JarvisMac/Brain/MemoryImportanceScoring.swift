import Foundation

// MARK: - MemoryImportanceScoring

/// Scores memory candidates for long-term importance.
///
/// Scoring is additive across five orthogonal signals:
/// - **Repetition** — mentioned across multiple turns / sessions
/// - **Emotional weight** — frustration, excitement, stress signals
/// - **Explicit emphasis** — user said "remember", "important", "critical"
/// - **Relevance decay** — older items are downweighted
/// - **Structural type** — decisions/bugs score higher than casual remarks
///
/// All scoring is synchronous and allocation-free on the hot path.
enum MemoryImportanceScoring {

    // MARK: - Public API

    /// Compute an importance score [0.0 – 1.0] for a memory candidate.
    static func score(
        for candidate: MemoryCandidate,
        repetitionCount: Int = 1,
        emotionalContext: EmotionalWeight = .neutral,
        ageDays: Double = 0
    ) -> Double {
        var total = baseScore(for: candidate.type)
        total += repetitionBonus(count: repetitionCount)
        total += emotionalContext.bonus
        total += emphasisBonus(in: candidate.rawText)
        total -= decayPenalty(ageDays: ageDays)
        return max(0.0, min(1.0, total))
    }

    /// Compute importance from raw text when no MemoryCandidate is available.
    static func scoreRawText(_ text: String, ageDays: Double = 0) -> Double {
        let type = inferType(from: text)
        return baseScore(for: type) + emphasisBonus(in: text) - decayPenalty(ageDays: ageDays)
    }

    // MARK: - Emotional weight

    enum EmotionalWeight {
        case neutral
        case mildlyEngaged
        case frustrated
        case excited
        case stressed

        var bonus: Double {
            switch self {
            case .neutral:        return 0.0
            case .mildlyEngaged:  return 0.05
            case .frustrated:     return 0.15
            case .excited:        return 0.10
            case .stressed:       return 0.12
            }
        }

        static func from(tone: DialogueTurn.EmotionalTone) -> EmotionalWeight {
            switch tone {
            case .neutral:    return .neutral
            case .frustrated: return .frustrated
            case .excited:    return .excited
            case .stressed:   return .stressed
            case .tired:      return .mildlyEngaged
            case .curious:    return .mildlyEngaged
            }
        }
    }

    // MARK: - Private scoring components

    static func baseScore(for type: MemoryCandidateType) -> Double {
        switch type {
        case .roadmapChange:    return 0.75
        case .projectDecision:  return 0.70
        case .bugReport:        return 0.60
        case .projectProgress:  return 0.55
        case .personalFact:     return 0.55
        case .userPreference:   return 0.50
        case .idea:             return 0.45
        case .temporaryNote:    return 0.25
        case .discard:          return 0.0
        }
    }

    static func repetitionBonus(count: Int) -> Double {
        min(0.25, Double(max(0, count - 1)) * 0.05)
    }

    static func emphasisBonus(in text: String) -> Double {
        let lower = text.lowercased()
        let emphasisTokens = [
            "remember", "important", "critical", "must", "never forget",
            "key decision", "always", "never", "don't forget"
        ]
        let count = emphasisTokens.filter { lower.contains($0) }.count
        return min(0.20, Double(count) * 0.07)
    }

    static func decayPenalty(ageDays: Double) -> Double {
        min(0.20, ageDays / 30.0 * 0.20)
    }

    static func inferType(from text: String) -> MemoryCandidateType {
        let lower = text.lowercased()
        if lower.contains("bug") || lower.contains("crash") || lower.contains("error") { return .bugReport }
        if lower.contains("decide") || lower.contains("decision") || lower.contains("agreed") { return .projectDecision }
        if lower.contains("roadmap") || lower.contains("ship") || lower.contains("release") { return .roadmapChange }
        if lower.contains("prefer") || lower.contains("always use") || lower.contains("never use") { return .userPreference }
        if lower.contains("idea") || lower.contains("maybe") || lower.contains("what if") { return .idea }
        if lower.contains("remember") || lower.contains("my name") || lower.contains("i am") { return .personalFact }
        return .temporaryNote
    }
}
