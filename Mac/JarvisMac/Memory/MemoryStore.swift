import Foundation
import os

/// Stores user-directed long-term memories ("remember this", "remember that
/// my coffee order is a flat white"). Searchable via FTS5. Bounded to the
/// most recent 1 000 entries — older ones are pruned on insert.
final class MemoryStore {

    static let maxEntries = 1_000

    private let db: JarvisDatabase
    private let queue = DispatchQueue(label: "com.jarvis.memory", qos: .utility)

    init(db: JarvisDatabase) {
        self.db = db
    }

    // MARK: - Write

    /// Save a new memory. `tags` is optional comma-separated context (e.g. "preference,food").
    func remember(_ text: String, tags: String = "") {
        queue.async { [db] in
            do {
                try db.insertMemory(text: text, tags: tags)
                Log.memory.info("memory saved: \(text.safePreview(80), privacy: .private)")
                try Self.pruneIfNeeded(db: db)
            } catch {
                Log.memory.error("memory insert failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Read

    func all(limit: Int = 100) async -> [MemoryRow] {
        await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.recentMemories(limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    func search(query: String, limit: Int = 20) async -> [MemoryRow] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let escaped = ftsEscape(query)
        return await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.searchMemory(query: escaped, limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    // MARK: - Private

    private static func pruneIfNeeded(db: JarvisDatabase) throws {
        try db.exec("""
            DELETE FROM memory_entries
            WHERE id NOT IN (
                SELECT id FROM memory_entries ORDER BY ts DESC LIMIT \(maxEntries)
            )
            """)
    }

    private func ftsEscape(_ raw: String) -> String {
        raw.components(separatedBy: .whitespaces)
           .filter { !$0.isEmpty }
           .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
           .joined(separator: " OR ")
    }
}
