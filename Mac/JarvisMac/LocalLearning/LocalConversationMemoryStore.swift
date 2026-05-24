import Foundation

struct LocalConversationTurn: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let role: TurnRole
    let content: String
    let intent: String?
    let source: InteractionSource

    enum TurnRole: String, Codable {
        case user, assistant
    }
}

@MainActor
final class LocalConversationMemoryStore {
    private(set) var turns: [LocalConversationTurn] = []
    private let maxTurns = 100

    func addUserTurn(transcript: String, intent: String?, source: InteractionSource) {
        append(LocalConversationTurn(
            id: UUID(), timestamp: Date(), role: .user,
            content: transcript, intent: intent, source: source
        ))
    }

    func addAssistantTurn(response: String, intent: String?) {
        append(LocalConversationTurn(
            id: UUID(), timestamp: Date(), role: .assistant,
            content: response, intent: intent, source: .unknown
        ))
    }

    func recentContext(limit: Int) -> [LocalConversationTurn] {
        Array(turns.suffix(limit))
    }

    func lastUserTranscript() -> String? {
        turns.last(where: { $0.role == .user })?.content
    }

    func buildContextBlock(limit: Int = 6) -> String {
        let recent = recentContext(limit: limit)
        guard !recent.isEmpty else { return "" }
        let lines = recent.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
        return "[RECENT CONVERSATION]\n" + lines.joined(separator: "\n")
    }

    func clear() {
        turns.removeAll()
    }

    private func append(_ turn: LocalConversationTurn) {
        turns.append(turn)
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
    }
}
