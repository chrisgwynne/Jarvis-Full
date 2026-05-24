import Foundation

/// Persistent dedup set for proactivity providers.
///
/// Each provider holds one instance per logical category (e.g. Shopify orders,
/// GitHub notifications, Obsidian watch-tags).  The store survives app restarts
/// so already-announced items don't re-alert on relaunch — the audit found
/// several providers were re-firing alerts after every launch because their
/// dedup sets were in-memory only.
///
/// **Storage:** `~/Library/Application Support/JarvisMac/dedup/<name>.json`
/// with owner-only permissions (0o600 file inside a 0o700 directory).
///
/// **Concurrency:** all accessors are `@MainActor` so providers can call
/// `contains`/`insert` without async ceremony.  Disk writes are dispatched
/// to a private serial background queue so the main actor is never blocked
/// by file I/O.
///
/// **Cap:** entries are stored up to `maxEntries` (default 5000).  On overflow
/// the oldest 20 % is dropped in one shot (insertion-order eviction).  The
/// 20 % batch amortises the trim cost across many subsequent inserts.
///
/// **Crash safety:** writes are atomic (`Data.write(to:options: .atomic)` —
/// write-to-tmp + rename).  A crash mid-write leaves either the old or new
/// file fully intact, never a corrupt half-written file.
@MainActor
final class ProactivityDedupStore {

    // MARK: - Public state

    /// Identifier used as the filename (sanitised; defaults like "shopify.orders").
    let name: String

    /// Maximum entries kept on disk + in memory.
    let maxEntries: Int

    /// O(1) `contains` hot set.
    private(set) var entries: Set<String> = []

    // MARK: - Private state

    /// Insertion-ordered queue used purely for overflow eviction.
    /// Never queried in the hot path — append-only with occasional prefix-drop.
    private var insertionOrder: [String] = []

    private let fileURL: URL
    private let saveQueue: DispatchQueue

    // MARK: - Init

    init(name: String, maxEntries: Int = 5000) {
        self.name        = name
        self.maxEntries  = maxEntries
        self.saveQueue   = DispatchQueue(label: "com.jarvis.mac.dedup.\(name)",
                                         qos: .utility)

        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true))
            ?? fm.temporaryDirectory
        let dir = support
            .appendingPathComponent("JarvisMac", isDirectory: true)
            .appendingPathComponent("dedup",    isDirectory: true)
        // Best-effort dir creation with owner-only perms.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        self.fileURL = dir.appendingPathComponent("\(name).json")
        hydrate()
    }

    // MARK: - Public API

    /// O(1) membership test.
    func contains(_ id: String) -> Bool { entries.contains(id) }

    /// Inserts `id` if not present.  Returns `true` if the set actually
    /// changed (caller can use this to gate the announcement).
    @discardableResult
    func insert(_ id: String) -> Bool {
        guard !entries.contains(id) else { return false }
        entries.insert(id)
        insertionOrder.append(id)
        trimIfOverflowing()
        saveAsync()
        return true
    }

    /// Bulk insert — used when seeding from a known-recent batch (e.g. the
    /// Shopify "last 6 hours" first-poll seed).  One disk write covers the
    /// whole batch.
    func insertBatch(_ ids: [String]) {
        var changed = false
        for id in ids where !entries.contains(id) {
            entries.insert(id)
            insertionOrder.append(id)
            changed = true
        }
        if changed {
            trimIfOverflowing()
            saveAsync()
        }
    }

    /// Remove an entry (rare — used when a watch-tag is removed from a note,
    /// for example, so that re-adding the tag fires a fresh alert).
    func remove(_ id: String) {
        if entries.remove(id) != nil {
            insertionOrder.removeAll { $0 == id }
            saveAsync()
        }
    }

    /// Wipe the store (test/debug only).
    func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        saveAsync()
    }

    // MARK: - Persistence

    private struct OnDisk: Codable {
        let ids: [String]
        let savedAt: Date
    }

    /// Loads existing entries from disk if present.  Silently no-ops on a
    /// missing or corrupt file — the next save() will overwrite it.
    private func hydrate() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(OnDisk.self, from: data) else { return }
        // Clip to maxEntries in case the file was written by an older build
        // with a higher cap.  Keep the tail (newest) entries.
        let clipped = decoded.ids.suffix(maxEntries)
        self.insertionOrder = Array(clipped)
        self.entries        = Set(clipped)
    }

    /// Drops the oldest 20 % of entries when the set exceeds `maxEntries`.
    ///
    /// `insertionOrder` can be shorter than `entries` if the store was
    /// hydrated from a truncated snapshot or if a bug caused the two
    /// collections to diverge.  Clamping `drop` to
    /// `insertionOrder.count` prevents the fatal
    /// `Range requires lowerBound <= upperBound` crash that was
    /// observed in production when 464 news items were queued at once.
    private func trimIfOverflowing() {
        guard entries.count > maxEntries else { return }
        let want  = maxEntries * 4 / 5           // target 80 % capacity after trim
        let ideal = entries.count - want          // how many we'd like to drop
        let drop  = min(ideal, insertionOrder.count)  // never exceed what we have
        guard drop > 0 else { return }
        let evict = insertionOrder.prefix(drop)
        entries.subtract(evict)
        insertionOrder.removeFirst(drop)
    }

    /// Dispatch a serialised atomic write off the main actor.  Multiple rapid
    /// inserts produce multiple writes (each tiny) but they're ordered by the
    /// serial queue, so the on-disk file is always consistent with some past
    /// state of the in-memory set.
    private func saveAsync() {
        let snapshot = insertionOrder
        let url = fileURL
        saveQueue.async {
            Self.writeAtomically(snapshot, to: url)
        }
    }

    private static func writeAtomically(_ ids: [String], to url: URL) {
        let payload = OnDisk(ids: ids, savedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: url.path)
    }
}
