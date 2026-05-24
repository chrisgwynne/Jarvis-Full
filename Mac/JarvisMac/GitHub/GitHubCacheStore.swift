import Foundation

// MARK: - GitHubCacheStore
// Thread-safe in-memory + disk cache for GitHub API responses.
// Reduces API calls, respects rate limits, survives short app restarts.

@MainActor
final class GitHubCacheStore {
    static let shared = GitHubCacheStore()

    // Per-key cache entries
    private var entries: [String: CacheEntry] = [:]

    // Default TTLs
    enum TTL {
        static let repos:      TimeInterval = 300    //  5 min
        static let issues:     TimeInterval = 120    //  2 min
        static let prs:        TimeInterval = 120
        static let commits:    TimeInterval = 60     //  1 min
        static let actions:    TimeInterval = 30     // 30 sec (CI moves fast)
        static let search:     TimeInterval = 600    // 10 min
        static let roadmap:    TimeInterval = 300
        static let review:     TimeInterval = 600
    }

    private struct CacheEntry {
        let data: Data
        let expiresAt: Date
        var isValid: Bool { expiresAt > Date() }
    }

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac/GitHubCache", isDirectory: true)
        fileURL = dir.appendingPathComponent("cache_index.json")
        loadFromDisk()
    }

    // MARK: - Read / Write

    func get<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let entry = entries[key], entry.isValid else {
            entries.removeValue(forKey: key)
            return nil
        }
        return try? JSONDecoder().decode(type, from: entry.data)
    }

    func set<T: Encodable>(_ value: T, key: String, ttl: TimeInterval) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        entries[key] = CacheEntry(data: data, expiresAt: Date().addingTimeInterval(ttl))
        saveToDisk()
    }

    func invalidate(key: String) {
        entries.removeValue(forKey: key)
    }

    func invalidateAll(prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    func invalidateEverything() {
        entries.removeAll()
        saveToDisk()
    }

    // MARK: - Convenience key builders

    static func key(repo: String, resource: String) -> String {
        "repo.\(repo.replacingOccurrences(of: "/", with: ".")).\(resource)"
    }

    static func key(resource: String) -> String {
        "gh.\(resource)"
    }

    // MARK: - Diagnostics

    var entryCount: Int { entries.count }
    var validEntryCount: Int { entries.values.filter(\.isValid).count }

    // MARK: - Persistence

    private struct PersistedEntry: Codable {
        let key: String
        let data: Data
        let expiresAt: Date
    }

    private func saveToDisk() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let valid = entries.map { PersistedEntry(key: $0.key, data: $0.value.data, expiresAt: $0.value.expiresAt) }
        if let data = try? JSONEncoder().encode(valid) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode([PersistedEntry].self, from: data)
        else { return }
        for entry in persisted where entry.expiresAt > Date() {
            entries[entry.key] = CacheEntry(data: entry.data, expiresAt: entry.expiresAt)
        }
    }
}
