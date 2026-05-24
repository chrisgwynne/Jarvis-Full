import Foundation

// MARK: - EntityMemoryGraph

@MainActor
final class EntityMemoryGraph {

    static let shared = EntityMemoryGraph()

    private var nodes: [String: EntityMemNode] = [:]
    private var aliasIndex: [String: String] = [:]
    private var relationships: [EntityMemRelationship] = []
    private var saveTask: Task<Void, Never>?

    private static let maxNodes = 500
    private static let maxRelationships = 1_000

    private var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("JarvisMac/entity_memory.json")
    }

    // MARK: - Upsert

    func upsert(_ node: EntityMemNode) {
        if let existing = nodes.values.first(where: {
            $0.entityKind == node.entityKind &&
            $0.canonicalName.lowercased() == node.canonicalName.lowercased()
        }) {
            var merged = existing
            merged.mentionCount += 1
            merged.lastMentionedAt = Date()
            merged.lastReferencedAt = Date()
            let newAliases = node.aliases.filter { !merged.aliases.contains($0) }
            merged.aliases.append(contentsOf: newAliases)
            merged.associatedDevices = Array(Set(merged.associatedDevices + node.associatedDevices))
            merged.associatedApps = Array(Set(merged.associatedApps + node.associatedApps))
            merged.associatedUrls = Array(Set(merged.associatedUrls + node.associatedUrls))
            for (k, v) in node.metadata { merged.metadata[k] = v }
            nodes[existing.id] = merged
            rebuildAliasIndex(for: merged)
        } else {
            nodes[node.id] = node
            rebuildAliasIndex(for: node)
        }
        scheduleSave()
    }

    // MARK: - Query

    func all() -> [EntityMemNode] { Array(nodes.values) }

    func node(id: String) -> EntityMemNode? { nodes[id] }

    func find(canonicalName: String, kind: EntityMemKind? = nil) -> EntityMemNode? {
        nodes.values.first {
            $0.canonicalName.lowercased() == canonicalName.lowercased() &&
            (kind == nil || $0.entityKind == kind)
        }
    }

    func nodeForAlias(_ alias: String) -> EntityMemNode? {
        guard let id = aliasIndex[alias.lowercased()] else { return nil }
        return nodes[id]
    }

    func recent(limit: Int = 10, kind: EntityMemKind? = nil) -> [EntityMemNode] {
        nodes.values
            .filter { kind == nil || $0.entityKind == kind }
            .sorted { $0.lastMentionedAt > $1.lastMentionedAt }
            .prefix(limit).map { $0 }
    }

    func topSalient(limit: Int = 5) -> [EntityMemNode] {
        nodes.values
            .filter { !$0.isExpired }
            .sorted { $0.relevanceScore() > $1.relevanceScore() }
            .prefix(limit).map { $0 }
    }

    func byKind(_ kind: EntityMemKind, limit: Int = 10) -> [EntityMemNode] {
        nodes.values
            .filter { $0.entityKind == kind && !$0.isExpired }
            .sorted { $0.relevanceScore() > $1.relevanceScore() }
            .prefix(limit).map { $0 }
    }

    func markReferenced(id: String) {
        guard var node = nodes[id] else { return }
        node.lastReferencedAt = Date()
        node.lastMentionedAt = Date()
        node.mentionCount += 1
        nodes[id] = node
        scheduleSave()
    }

    func updateSalience(id: String, salience: Double) {
        guard var node = nodes[id] else { return }
        node.salience = max(0, min(1, salience))
        nodes[id] = node
    }

    // MARK: - Relationships

    func addRelationship(from fromId: String, to toId: String, kind: String) {
        guard nodes[fromId] != nil, nodes[toId] != nil else { return }
        let rel = EntityMemRelationship(fromId: fromId, toId: toId, kind: kind, createdAt: Date())
        relationships.append(rel)
        if relationships.count > Self.maxRelationships {
            relationships = Array(relationships.suffix(Self.maxRelationships))
        }
        scheduleSave()
    }

    func relationships(from nodeId: String) -> [EntityMemRelationship] {
        relationships.filter { $0.fromId == nodeId }
    }

    func relationships(to nodeId: String) -> [EntityMemRelationship] {
        relationships.filter { $0.toId == nodeId }
    }

    // MARK: - Lifecycle

    func prune() {
        let expiredIds = nodes.values.filter(\.isExpired).map(\.id)
        for id in expiredIds { removeNode(id: id) }

        if nodes.count > Self.maxNodes {
            let sorted = nodes.values.sorted { $0.relevanceScore() < $1.relevanceScore() }
            for node in sorted.prefix(nodes.count - Self.maxNodes) { removeNode(id: node.id) }
        }
        scheduleSave()
    }

    // MARK: - Persistence

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(GraphPayload.self, from: data),
              payload.schemaVersion == 1 else { return }
        nodes = Dictionary(uniqueKeysWithValues: payload.nodes.map { ($0.id, $0) })
        relationships = payload.relationships
        rebuildAllAliasIndexes()
    }

    // MARK: - Private

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveToDisk()
        }
    }

    private func saveToDisk() {
        let payload = GraphPayload(
            schemaVersion: 1, nodes: Array(nodes.values), relationships: relationships)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomicWrite)
    }

    private func rebuildAliasIndex(for node: EntityMemNode) {
        aliasIndex[node.canonicalName.lowercased()] = node.id
        for alias in node.aliases { aliasIndex[alias.lowercased()] = node.id }
    }

    private func rebuildAllAliasIndexes() {
        aliasIndex.removeAll()
        for node in nodes.values { rebuildAliasIndex(for: node) }
    }

    private func removeNode(id: String) {
        guard let node = nodes[id] else { return }
        nodes.removeValue(forKey: id)
        aliasIndex.removeValue(forKey: node.canonicalName.lowercased())
        for alias in node.aliases { aliasIndex.removeValue(forKey: alias.lowercased()) }
        relationships.removeAll { $0.fromId == id || $0.toId == id }
    }
}

// MARK: - Codable payload

private struct GraphPayload: Codable {
    let schemaVersion: Int
    let nodes: [EntityMemNode]
    let relationships: [EntityMemRelationship]
}
