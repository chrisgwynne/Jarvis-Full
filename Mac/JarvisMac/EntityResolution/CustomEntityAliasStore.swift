import Foundation

// MARK: - CustomEntityAliasStore

/// Persists user-taught entity aliases across sessions.
/// File: ~/Library/Application Support/JarvisMac/custom_entity_aliases.json
@MainActor
final class CustomEntityAliasStore {

    static let shared = CustomEntityAliasStore()

    struct AliasEntry: Codable, Identifiable {
        var id: String { alias + ":" + entityId }
        let alias: String
        let entityId: String
        let displayName: String
        let entityType: EntityType
        let url: URL?
    }

    private var entries: [AliasEntry] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first!
            let dir = support.appendingPathComponent("JarvisMac")
            try? FileManager.default.createDirectory(at: dir,
                withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("custom_entity_aliases.json")
        }
        load()
    }

    // MARK: - CRUD

    func save(_ entry: AliasEntry) {
        // Replace existing alias or append
        if let idx = entries.firstIndex(where: { $0.alias == entry.alias }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    func allAliases() -> [AliasEntry] { entries }

    func remove(alias: String) {
        entries.removeAll { $0.alias == alias }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AliasEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
