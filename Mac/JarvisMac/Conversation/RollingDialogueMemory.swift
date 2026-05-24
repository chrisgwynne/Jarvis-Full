import Foundation

// MARK: - RollingDialogueMemory

/// Unified rolling conversation memory with topic tracking and pronoun resolution.
///
/// Replaces / unifies LocalConversationMemoryStore with:
/// - Topic continuity across turns
/// - Pronoun resolution: "it" / "that" / "do it again"
/// - Active entity tracking
/// - Recency-weighted context for LLM injection
///
/// All state is @MainActor — no locking required.
@MainActor
final class RollingDialogueMemory {
    static let shared = RollingDialogueMemory()

    // MARK: - State

    private(set) var turns: [DialogueTurn] = []
    private(set) var activeTopic: String?
    private(set) var activeEntities: [String] = []
    private(set) var lastExecutedIntentLabel: String?
    private(set) var lastAssistantReply: String = ""
    private(set) var lastUserTranscript: String = ""
    private(set) var emotionalTone: DialogueTurn.EmotionalTone = .neutral

    private let maxTurns = 40
    private let topicWindowSeconds: Double = 300

    // MARK: - Add Turns

    func addUserTurn(
        _ text: String,
        intent: String? = nil,
        route: ConversationRoute? = nil,
        wasInterruption: Bool = false
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entities = extractEntities(from: cleaned)
        let topic = inferTopic(from: cleaned, intent: intent, existing: activeTopic)
        let tone = detectEmotionalTone(from: cleaned)

        let turn = DialogueTurn(
            id: UUID(),
            role: .user,
            rawTranscript: text,
            cleanedTranscript: cleaned,
            timestamp: Date(),
            intentLabel: intent,
            extractedEntities: entities,
            activeTopic: topic,
            emotionalTone: tone,
            route: route,
            toolsExecuted: intent.map { [$0] } ?? [],
            wasInterruption: wasInterruption
        )
        append(turn)

        lastUserTranscript = cleaned
        if let label = intent { lastExecutedIntentLabel = label }
        activeEntities = Array(Set(entities + activeEntities)).prefix(10).map { $0 }
        if let t = topic { activeTopic = t }
        emotionalTone = tone
    }

    func addAssistantTurn(_ text: String, intent: String? = nil) {
        let turn = DialogueTurn(
            id: UUID(),
            role: .assistant,
            rawTranscript: text,
            cleanedTranscript: text,
            timestamp: Date(),
            intentLabel: intent,
            extractedEntities: [],
            activeTopic: activeTopic,
            emotionalTone: .neutral,
            route: nil,
            toolsExecuted: [],
            wasInterruption: false
        )
        append(turn)
        lastAssistantReply = text
    }

    // MARK: - Pronoun / Reference Resolution

    /// Resolve a pronoun or reference word ("it", "that", "them") to its concrete referent.
    func resolve(_ word: String) -> String? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        switch w {
        case "it", "that", "this":
            return activeEntities.first ?? activeTopic
        case "them", "those", "these":
            if activeEntities.count >= 2 {
                return activeEntities.prefix(2).joined(separator: " and ")
            }
            return activeEntities.first ?? activeTopic
        default:
            return nil
        }
    }

    /// Returns true if the normalized transcript is a "do it again" / repeat request.
    func isRepeatRequest(_ normalized: String) -> Bool {
        let patterns = ["do it again", "do that again", "repeat that", "one more time",
                        "same again", "try again", "try that again"]
        return patterns.contains(where: { normalized.hasPrefix($0) || normalized.contains($0) })
    }

    /// Returns a human-readable summary of the active topic for "what were we talking about?" queries.
    func conversationSummary() -> String {
        guard !recentTurns.isEmpty else { return "We haven't talked about anything yet." }
        var parts: [String] = []
        if let topic = activeTopic { parts.append("We were discussing \(topic)") }
        if let last = turns.last(where: { $0.role == .user }) {
            parts.append("Your last message was: \(last.cleanedTranscript.prefix(80))")
        }
        if let reply = turns.last(where: { $0.role == .assistant }) {
            parts.append("I said: \(reply.cleanedTranscript.prefix(80))")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Context Building

    var recentTurns: [DialogueTurn] {
        turns.filter { $0.isRecent }
    }

    /// Build a compact context block for LLM injection.
    func buildContextBlock(limit: Int = 8) -> String {
        let recent = recentTurns.suffix(limit)
        guard !recent.isEmpty else { return "" }

        var lines: [String] = []
        if let topic = activeTopic {
            lines.append("[Active topic: \(topic)]")
        }
        lines += recent.map { t in
            let role = t.role == .user ? "User" : "Jarvis"
            return "\(role): \(t.cleanedTranscript)"
        }
        return "[DIALOGUE CONTEXT]\n" + lines.joined(separator: "\n")
    }

    func clear() {
        turns.removeAll()
        activeTopic = nil
        activeEntities = []
        lastExecutedIntentLabel = nil
        lastAssistantReply = ""
        lastUserTranscript = ""
        emotionalTone = .neutral
    }

    // MARK: - Private Helpers

    private func append(_ turn: DialogueTurn) {
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    /// Lightweight entity extraction: quoted strings and capitalised non-stop words.
    private func extractEntities(from text: String) -> [String] {
        var entities: [String] = []

        // Quoted strings
        if let regex = try? NSRegularExpression(pattern: #""([^"]{2,40})"|'([^']{2,40})'"#) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                for g in 1...2 {
                    if let r = Range(match.range(at: g), in: text) {
                        entities.append(String(text[r]))
                    }
                }
            }
        }

        // Capitalised mid-sentence words (crude proper noun detection)
        let stopWords: Set<String> = ["The", "A", "An", "And", "But", "Or", "For",
                                       "In", "On", "At", "Is", "It", "I", "My", "We",
                                       "You", "He", "She", "They", "This", "That"]
        let words = text.components(separatedBy: .whitespaces)
        for (i, word) in words.enumerated() where i > 0 {
            let clean = word.trimmingCharacters(in: .punctuationCharacters)
            if clean.count >= 3,
               let first = clean.first, first.isUppercase,
               !stopWords.contains(clean) {
                entities.append(clean)
            }
        }

        return Array(Set(entities)).prefix(5).map { $0 }
    }

    /// Infer a topic label from the turn content.
    private func inferTopic(from text: String, intent: String?, existing: String?) -> String? {
        // Preserve existing topic if text references it
        if let topic = existing, text.lowercased().contains(topic.lowercased()) {
            return topic
        }
        // Use intent label as topic hint
        if let label = intent {
            let clean = label.components(separatedBy: "(").first ?? label
            if clean != "unknown" { return clean }
        }
        // Extract significant noun from text
        let stop: Set<String> = ["what", "how", "why", "when", "where", "who", "is", "are",
                                   "was", "were", "the", "a", "an", "and", "or", "but",
                                   "in", "on", "at", "to", "i", "you", "we", "they", "it",
                                   "this", "that", "do", "did", "does", "have", "has", "can"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stop.contains($0) }
        return words.first
    }

    /// Simple heuristic emotional tone detection.
    private func detectEmotionalTone(from text: String) -> DialogueTurn.EmotionalTone {
        let t = text.lowercased()
        let frustrationSignals = ["still", "again", "keeps", "won't", "doesn't", "broken",
                                   "annoying", "frustrated", "ugh", "why", "not working"]
        let excitedSignals = ["great", "amazing", "finally", "yes", "awesome", "perfect", "love"]
        let stressSignals = ["urgent", "asap", "quickly", "hurry", "deadline", "critical", "need"]
        let tiredSignals = ["tired", "exhausted", "rough day", "long day", "drained"]

        if frustrationSignals.filter({ t.contains($0) }).count >= 2 { return .frustrated }
        if stressSignals.contains(where: { t.contains($0) }) { return .stressed }
        if tiredSignals.contains(where: { t.contains($0) }) { return .tired }
        if excitedSignals.contains(where: { t.contains($0) }) { return .excited }
        return .neutral
    }
}
