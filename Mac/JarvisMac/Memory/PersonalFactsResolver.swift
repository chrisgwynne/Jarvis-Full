import Foundation

/// Builds short, spoken answers to identity and personal-fact questions
/// by pulling from PreferencesStore and stored memories. No LLM, no async
/// for the identity cases — answers in microseconds.
struct PersonalFactsResolver {

    // MARK: - Identity answers (synchronous)

    /// "What is my name?" / "Who am I?"
    func answerMyName(userName: String) -> String {
        guard !userName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "I don't know your name yet. You can set it in Settings."
        }
        return "Your name is \(userName)."
    }

    /// "What's your name?" / "Who are you?"
    func answerAssistantName(assistantName: String) -> String {
        let name = assistantName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Jarvis"
            : assistantName
        return "I'm \(name), your personal AI assistant."
    }

    /// "Who am I?" — richer variant combining name + any quick personal fact
    func answerWhoAmI(userName: String, assistantName: String) -> String {
        let assistant = assistantName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Jarvis"
            : assistantName
        if userName.trimmingCharacters(in: .whitespaces).isEmpty {
            return "I'm \(assistant). I don't have your name on file — you can add it in Settings."
        }
        return "You're \(userName), and I'm \(assistant). How can I help?"
    }

    // MARK: - Memory-based answers (async, up to 5 facts)

    /// "What do you know about me?" — loads recent memories and speaks a short list.
    func buildPersonalFactsAnswer(userName: String, memories: [MemoryRow], limit: Int = 5) -> String {
        let capped = Array(memories.prefix(limit))
        if capped.isEmpty {
            if userName.trimmingCharacters(in: .whitespaces).isEmpty {
                return "I don't have anything stored about you yet. Tell me something to remember and I'll keep it."
            }
            return "Your name is \(userName). I don't have anything else stored about you yet."
        }
        var lines: [String] = []
        if !userName.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Your name is \(userName).")
        }
        lines.append("Here's what I remember:")
        for row in capped {
            lines.append("• \(row.text)")
        }
        if memories.count > limit {
            lines.append("I can show more in the memory overlay if you like.")
        }
        return lines.joined(separator: " ")
    }

    /// "What do you remember?" — spoken summary of the most recent memories.
    /// Intentionally does NOT open the overlay; caller may do so separately.
    func buildMemoryAnswer(memories: [MemoryRow], limit: Int = 5) -> String {
        let capped = Array(memories.prefix(limit))
        guard !capped.isEmpty else {
            return "I don't have anything stored in memory yet."
        }
        var lines = ["Here's what I remember:"]
        for row in capped {
            lines.append("• \(row.text)")
        }
        if memories.count > limit {
            lines.append("I can show more if you want.")
        }
        return lines.joined(separator: " ")
    }
}
