import Foundation
import os

/// Thread-safe store for the spoken conversation log. Every user utterance
/// and assistant response is saved here and can be searched via FTS5.
/// All DB access runs on a private serial queue; results are returned as
/// plain value types so callers don't need to worry about threading.
final class ConversationStore {

    private let db: JarvisDatabase
    private let queue = DispatchQueue(label: "com.jarvis.conv", qos: .utility)

    init(db: JarvisDatabase) {
        self.db = db
    }

    // MARK: - Write

    func saveUserTurn(_ text: String) {
        queue.async { [db] in
            do {
                try db.insertConversation(role: "user", text: text)
                Log.memory.debug("conv saved [user]: \(text.prefix(80))")
            } catch {
                Log.memory.error("conv insert failed: \(error.localizedDescription)")
            }
        }
    }

    /// Save with intent metadata (requires migration v2 columns).
    func saveUserTurn(_ text: String, intent: String, sessionId: String) {
        queue.async { [db] in
            do {
                try db.insertConversationFull(role: "user", text: text,
                                              intent: intent, sessionId: sessionId)
                Log.memory.debug("conv saved [user/\(intent)]: \(text.prefix(60))")
            } catch {
                // v2 columns may not exist yet — fall back to basic insert.
                do {
                    try db.insertConversation(role: "user", text: text)
                } catch let fallbackError {
                    Log.memory.error("conv insert failed: \(fallbackError.localizedDescription)")
                }
            }
        }
    }

    func saveAssistantTurn(_ text: String) {
        queue.async { [db] in
            do {
                try db.insertConversation(role: "assistant", text: text)
                Log.memory.debug("conv saved [assistant]: \(text.prefix(80))")
            } catch {
                Log.memory.error("conv insert failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Read

    func recent(limit: Int = 50) async -> [ConversationRow] {
        await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.recentConversations(limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    func search(query: String, limit: Int = 20) async -> [ConversationRow] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let escaped = ftsEscape(query)
        return await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.searchConversations(query: escaped, limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    // MARK: - Helpers

    private func ftsEscape(_ raw: String) -> String {
        raw.components(separatedBy: .whitespaces)
           .filter { !$0.isEmpty }
           .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
           .joined(separator: " OR ")
    }
}
