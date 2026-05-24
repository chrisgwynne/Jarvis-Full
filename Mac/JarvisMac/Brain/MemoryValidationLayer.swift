import Foundation

// MARK: - MemoryValidationLayer

/// Quality gate for episodic memory ingestion.
/// Prevents STT noise, false wakes, weak chatter, and hallucinated assumptions
/// from polluting the episodic store. All heuristics are intentionally conservative
/// to avoid blocking legitimate memories.
@MainActor
enum MemoryValidationLayer {

    struct ValidationResult {
        let shouldStore: Bool
        let reason: String
        let adjustedImportance: Double
        let adjustedConfidence: Double
    }

    struct SessionContext {
        var isConversationActive: Bool = false
        var emotionalTone: DialogueTurn.EmotionalTone = .neutral
        var sttConfidence: Double = 1.0
        var sessionDepth: Int = 0
    }

    // MARK: - Main Validation Gate

    static func validate(
        text: String,
        title: String,
        type: MemoryCandidateType,
        importance: Double,
        confidence: Double,
        sessionContext: SessionContext? = nil
    ) -> ValidationResult {
        let ctx = sessionContext ?? SessionContext()

        // Discard type is always rejected
        if type == .discard {
            return rejected("type_discard")
        }

        // Too short to carry any information
        let wordCount = text.split(separator: " ").count
        if wordCount < 4 {
            return rejected("too_short words=\(wordCount)")
        }

        // STT noise, false wake words, weak chatter
        if isSTTNoise(text) { return rejected("stt_noise") }
        if isFalseWake(text) { return rejected("false_wake") }
        if isWeakChatter(text) { return rejected("weak_chatter") }

        // Apply STT confidence penalty
        let effectiveConfidence = max(0, min(1, confidence * ctx.sttConfidence))
        var adjustedImportance = max(0, importance)

        // Minimum threshold gate
        if adjustedImportance < 0.25 || effectiveConfidence < 0.35 {
            return ValidationResult(
                shouldStore: false,
                reason: "below_threshold i=\(String(format:"%.2f", adjustedImportance)) c=\(String(format:"%.2f", effectiveConfidence))",
                adjustedImportance: adjustedImportance,
                adjustedConfidence: effectiveConfidence
            )
        }

        // Penalise transient notes in shallow sessions
        if ctx.sessionDepth < 2 && type == .temporaryNote {
            adjustedImportance *= 0.7
        }

        return ValidationResult(
            shouldStore: true,
            reason: "ok",
            adjustedImportance: adjustedImportance,
            adjustedConfidence: effectiveConfidence
        )
    }

    // MARK: - Heuristics

    static func isSTTNoise(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count < 3
    }

    static func isFalseWake(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let wakeWords: Set<String> = ["jarvis", "hey jarvis", "okay jarvis", "hi jarvis", "ok jarvis"]
        if wakeWords.contains(lower) { return true }
        // Single word after normalisation is almost always noise
        return lower.split(separator: " ").count <= 1
    }

    static func isWeakChatter(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let fillers: Set<String> = [
            "yeah", "ok", "okay", "sure", "yes", "no", "maybe", "right",
            "uh huh", "mhm", "alright", "got it", "cool", "fine", "good",
            "thanks", "thank you", "nice", "great", "awesome", "perfect",
            "of course", "sounds good", "makes sense", "i see", "go ahead",
        ]
        return fillers.contains(lower)
    }

    static func hasSubstantiveContent(_ text: String) -> Bool {
        let stopWords: Set<String> = ["the", "a", "an", "is", "it", "in", "on", "at", "to", "and", "or", "but"]
        let words = text.lowercased().split(separator: " ").map(String.init)
        let substantive = words.filter { $0.count > 3 && !stopWords.contains($0) }
        return substantive.count >= 2
    }

    // MARK: - Helpers

    private static func rejected(_ reason: String) -> ValidationResult {
        ValidationResult(shouldStore: false, reason: reason, adjustedImportance: 0, adjustedConfidence: 0)
    }
}
