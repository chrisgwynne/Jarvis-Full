import Foundation

// MARK: - ContextGraphPersistence

/// Handles atomic serialization of the context graph to/from disk.
///
/// The file is stored at:
///   ~/Library/Application Support/JarvisMac/context_graph.json
///
/// Writes are debounced by 3 seconds to avoid excessive I/O during bursts of
/// ingestion activity (e.g. startup where refresh() is called immediately after
/// loadFromDisk()).
///
/// A schema version field allows forward-compatible migrations. If the file's
/// schema version exceeds the current version, it is silently ignored so that
/// a downgraded binary never crashes on a newer payload.
@MainActor final class ContextGraphPersistence {

    // MARK: - Constants

    static let currentSchemaVersion = 1
    static let defaultNodeCap = 600
    static let defaultEdgeCap = 1200

    // MARK: - Codable payload

    private struct Payload: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var nodes: [ContextNode]
        var edges: [ContextEdge]
    }

    // MARK: - State

    private(set) var lastSaveTime: Date?
    private(set) var persistedGraphLoaded = false

    private var saveTask: Task<Void, Never>?

    // MARK: - URL

    /// Allows injection of a custom URL for tests.
    private let customFileURL: URL?

    private var fileURL: URL {
        if let url = customFileURL { return url }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("context_graph.json")
    }

    // MARK: - Init

    init(fileURL: URL? = nil) {
        self.customFileURL = fileURL
    }

    // MARK: - Debounced Save

    /// Schedules a save after a 3-second debounce window.
    /// Multiple calls within the window collapse to one write.
    func scheduleSave(graph: ContextGraph) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.save(graph: graph)
        }
    }

    // MARK: - Immediate Save

    /// Encodes the graph and writes atomically.
    /// Silently no-ops on encoding or I/O failures.
    func save(graph: ContextGraph) {
        let payload = Payload(
            schemaVersion: Self.currentSchemaVersion,
            savedAt:       Date(),
            nodes:         Array(graph.nodesByID.values),
            edges:         Array(graph.edgesByID.values)
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload) else { return }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        lastSaveTime = Date()
    }

    // MARK: - Load

    /// Loads a persisted graph from disk into `graph`.
    ///
    /// - Missing file: silently returns, graph unchanged.
    /// - Corrupt JSON: silently returns, graph unchanged.
    /// - Schema version newer than current: silently returns (forward compatibility).
    /// Maximum on-disk file size we will attempt to read. Files larger than this
    /// indicate unbounded prior-session growth — skip them and cold-start instead
    /// of OOM-ing during the read itself.
    static let maxLoadFileSizeBytes = 5 * 1024 * 1024   // 5 MB

    func load(into graph: ContextGraph) {
        // Reject oversized files before reading them into memory.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > Self.maxLoadFileSizeBytes {
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let payload = try? dec.decode(Payload.self, from: data),
              payload.schemaVersion <= Self.currentSchemaVersion else { return }

        // Load nodes first so edge endpoints are resolvable.
        for node in payload.nodes {
            graph.upsertNode(node)
        }
        // Only load edges whose endpoints survived the node load.
        for edge in payload.edges {
            guard graph.nodesByID[edge.from] != nil,
                  graph.nodesByID[edge.to]   != nil else { continue }
            graph.upsertEdge(edge)
        }
        // Prune immediately — accumulated stale nodes from prior sessions
        // may exceed current caps before any new ingestion runs.
        graph.prune()
        persistedGraphLoaded = true
    }

    // MARK: - Reset

    /// Deletes the persisted file and resets in-memory state.
    /// Intended for tests and schema migrations.
    func resetPersistedFile() {
        try? FileManager.default.removeItem(at: fileURL)
        persistedGraphLoaded = false
        lastSaveTime = nil
    }
}
