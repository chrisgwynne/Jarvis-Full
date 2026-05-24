import Foundation
import OSLog

private let contextLogger = Logger(subsystem: "com.jarvis.brain", category: "context")

// MARK: - ContextEntry

struct ContextEntry {
    let key: String
    let value: JSONValue
    let sourceDeviceId: String
    let createdAt: Date
    let expiresAt: Date
}

// MARK: - ContextStore

/// Short-lived cross-device context. 24-hour retention. Capped at 100 entries per key.
final class ContextStore {
    static let shared = ContextStore()
    private init() {}

    private var entries: [String: ContextEntry] = [:]
    private let lock = NSLock()

    private let maxEntries = 100

    // MARK: - Well-known keys

    static let lastTranscript  = "last_transcript"
    static let lastFileTransfer = "last_file_transfer"
    static let lastRemoteAction = "last_remote_action"
    static let lastHandoff     = "last_handoff"
    static let lastClipboard   = "last_clipboard"
    static let lastCommPrompt  = "last_comm_prompt"

    // MARK: - Write

    func set(key: String,
             value: JSONValue,
             sourceDeviceId: String,
             ttlSeconds: TimeInterval = 86400) {
        lock.withLock {
            let now = Date()
            let entry = ContextEntry(
                key:            key,
                value:          value,
                sourceDeviceId: sourceDeviceId,
                createdAt:      now,
                expiresAt:      now.addingTimeInterval(ttlSeconds)
            )

            // Enforce cap by evicting the oldest entry if needed
            if entries.count >= maxEntries && entries[key] == nil {
                evictOldest()
            }

            entries[key] = entry
            contextLogger.debug("context: set key=\(key) ttl=\(ttlSeconds)s source=\(sourceDeviceId)")
        }
    }

    // MARK: - Read

    func get(key: String) -> ContextEntry? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            if entry.expiresAt < Date() {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry
        }
    }

    func getAll() -> [String: ContextEntry] {
        lock.withLock {
            let now = Date()
            return entries.filter { $0.value.expiresAt > now }
        }
    }

    // MARK: - Eviction

    func evictExpired() {
        lock.withLock {
            let now = Date()
            let before = entries.count
            entries = entries.filter { $0.value.expiresAt > now }
            let evicted = before - entries.count
            if evicted > 0 {
                contextLogger.debug("context: evicted \(evicted) expired entries")
            }
        }
    }

    // MARK: - Private helpers

    /// Must be called while `lock` is held.
    private func evictOldest() {
        if let oldest = entries.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
            entries.removeValue(forKey: oldest.key)
            contextLogger.debug("context: evicted oldest entry key=\(oldest.key) to stay under cap")
        }
    }
}
