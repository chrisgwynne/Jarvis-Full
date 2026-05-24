import Foundation

/// In-memory response cache for deterministic and conversational answers.
/// Keyed by a stable string; values expire after a configurable TTL.
/// Uses Swift actor isolation for thread safety.
///
/// Wire into FastResponseRouter so repeated capability/identity/state queries
/// are answered in < 1 ms without rebuilding strings from scratch each time.
actor ResponseCache {

    // MARK: - Keys

    enum Key {
        static let identity      = "identity"
        static let capabilities  = "capabilities"
        static let architecture  = "architecture"
        static let runtimeState  = "runtime_state"
        static let integrations  = "integrations"
        static let memoryBrief   = "memory_brief"
        static let timeResponse  = "time_response"   // very short TTL

        static func custom(_ s: String) -> String { "cx_\(s)" }
    }

    // MARK: - TTLs

    enum TTL {
        static let identity:     TimeInterval = 600   // 10 min — name etc. rarely changes
        static let capabilities: TimeInterval = 300   // 5 min
        static let architecture: TimeInterval = 600   // 10 min
        static let runtimeState: TimeInterval = 30    // 30 sec — model may change
        static let integrations: TimeInterval = 120   // 2 min
        static let memoryBrief:  TimeInterval = 120   // 2 min
        static let timeResponse: TimeInterval = 10    // 10 sec (clock changes)
    }

    // MARK: - Cap

    /// Hard upper bound on cache entries.  Without this the cache grows
    /// unbounded for the lifetime of the app — short-TTL entries (e.g.
    /// `timeResponse`, 10 s) accumulate even when never re-read because
    /// nothing was sweeping them.  500 entries is generous: at ~2 KB per
    /// answer that's ~1 MB of memory, while still being smaller than the
    /// number of distinct short-lived `custom_…` keys a busy session
    /// produces in a day.
    static let maxEntries: Int = 500

    // MARK: - Storage

    private struct Entry {
        let value: String
        let expiresAt: Date
        /// Touched on every `get` so eviction can pick a true LRU victim.
        var lastAccessedAt: Date
        var isExpired: Bool { Date() > expiresAt }
    }

    private var store: [String: Entry] = [:]

    // MARK: - Diagnostics

    private(set) var hits:      Int = 0
    private(set) var misses:    Int = 0
    private(set) var evictions: Int = 0

    var hitRate: Double {
        let total = hits + misses
        return total > 0 ? Double(hits) / Double(total) : 0.0
    }

    // MARK: - Access

    func get(_ key: String) -> String? {
        if var entry = store[key], !entry.isExpired {
            entry.lastAccessedAt = Date()
            store[key] = entry           // touch — promotes recency for LRU
            hits += 1
            return entry.value
        }
        store.removeValue(forKey: key)
        misses += 1
        return nil
    }

    func set(_ key: String, value: String, ttl: TimeInterval) {
        // Capacity check happens on insert, not on replace.  Storing the same
        // key twice is a refresh, not a new entry.
        if store[key] == nil, store.count >= Self.maxEntries {
            evictForCapacity()
        }
        store[key] = Entry(value: value,
                           expiresAt: Date().addingTimeInterval(ttl),
                           lastAccessedAt: Date())
    }

    func invalidate(_ key: String) {
        store.removeValue(forKey: key)
    }

    func invalidateAll() {
        store.removeAll()
        evictions = 0
    }

    /// Prune stale entries. Safe to call from a periodic timer.
    func pruneExpired() {
        store = store.filter { !$0.value.isExpired }
    }

    // MARK: - Eviction

    /// Two-step capacity recovery:
    ///   1. Remove anything already expired (free work).
    ///   2. If still at/over cap, drop the single least-recently-accessed
    ///      entry.  One eviction per insert keeps the steady-state size
    ///      pinned at exactly `maxEntries` without doing O(n²) work.
    private func evictForCapacity() {
        let before = store.count
        pruneExpired()
        // If TTL prune already brought us back under, we're done.
        guard store.count >= Self.maxEntries else {
            if store.count < before { evictions += (before - store.count) }
            return
        }
        if let oldestKey = store.min(by: {
            $0.value.lastAccessedAt < $1.value.lastAccessedAt
        })?.key {
            store.removeValue(forKey: oldestKey)
            evictions += 1
        }
    }
}
