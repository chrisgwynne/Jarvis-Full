import Foundation
import OSLog

/// Bounded store of recent cross-device handoff contexts.
/// Entries expire after 24 hours. Max 20 entries.
final class HandoffContextStore {
    static let shared = HandoffContextStore()
    private init() {}

    struct HandoffEntry {
        let id: String
        let sourceDeviceId: String
        let key: String          // "url", "text", "conversation", "file"
        let summary: String      // max 200 chars, no raw transcripts
        let createdAt: Date
    }

    private var entries: [HandoffEntry] = []
    private let lock = NSLock()
    private static let maxEntries = 20
    private static let ttlSeconds: TimeInterval = 86400

    func record(sourceDeviceId: String, key: String, value: String) {
        lock.withLock {
            evictExpired()
            let summary = String(value.prefix(200))
            let entry = HandoffEntry(
                id: UUID().uuidString,
                sourceDeviceId: sourceDeviceId,
                key: key,
                summary: summary,
                createdAt: Date()
            )
            entries.append(entry)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        }
    }

    var recent: [HandoffEntry] {
        lock.withLock {
            evictExpired()
            return Array(entries.reversed())
        }
    }

    func recentSummary(limit: Int = 5) -> [[String: String]] {
        recent.prefix(limit).map { ["id": $0.id, "key": $0.key, "summary": $0.summary, "from": $0.sourceDeviceId] }
    }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-Self.ttlSeconds)
        entries.removeAll { $0.createdAt < cutoff }
    }
}
