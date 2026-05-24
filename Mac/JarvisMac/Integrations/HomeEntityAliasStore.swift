import Foundation
import Observation

/// Persists user-defined friendly name → HA entity ID mappings.
/// Example: "desk lamp" → "light.office_desk_lamp_main"
///
/// Saved to ~/Library/Application Support/JarvisMac/ha_aliases.json
@Observable
@MainActor
final class HomeEntityAliasStore {

    // MARK: - Published state
    private(set) var aliases: [HAEntityAlias] = []

    // MARK: - Persistence
    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ha_aliases.json")
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Init
    init() { load() }

    // MARK: - Lookup

    /// Returns the entity ID for a given friendly name (case-insensitive).
    func entityID(for name: String) -> String? {
        let lower = name.lowercased()
        return aliases.first { $0.friendlyName.lowercased() == lower }?.entityID
    }

    /// Resolves a spoken name to an entity ID, checking aliases first.
    /// Falls back to the original name if no alias found.
    func resolve(_ name: String) -> String {
        entityID(for: name) ?? name
    }

    // MARK: - Mutations

    func add(friendlyName: String, entityID: String) {
        let alias = HAEntityAlias(
            friendlyName: friendlyName.trimmingCharacters(in: .whitespaces),
            entityID: entityID.trimmingCharacters(in: .whitespaces))
        // Replace existing with same friendly name
        aliases.removeAll { $0.friendlyName.lowercased() == alias.friendlyName.lowercased() }
        aliases.append(alias)
        aliases.sort { $0.friendlyName < $1.friendlyName }
        save()
    }

    func remove(id: UUID) {
        aliases.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        aliases.removeAll()
        save()
    }

    // MARK: - Persistence
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([HAEntityAlias].self, from: data)
        else { return }
        aliases = decoded
    }

    func save() {
        guard let data = try? encoder.encode(aliases) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Model

struct HAEntityAlias: Identifiable, Codable {
    var id: UUID = UUID()
    var friendlyName: String   // what the user says, e.g. "desk lamp"
    var entityID: String       // HA entity_id, e.g. "light.office_desk_lamp"
    var notes: String = ""     // optional user notes
}
