import Foundation

// MARK: - EntityNode

struct EntityNode: Identifiable, Codable, Equatable {
    let id: String         // stable unique key e.g. "app:Safari", "memory:uuid"
    let kind: EntityKind
    let label: String      // human display name
    var firstSeen: Date
    var lastSeen: Date
    var weight: Double     // usage frequency, 0–1 (normalised)

    enum EntityKind: String, Codable, CaseIterable {
        // UI-domain
        case app
        case overlay
        case memory
        case command
        case website
        // Project-domain
        case project
        case repo           // GitHub / local repository
        case file           // source file or document
        case feature        // product feature or capability
        case bug            // known bug or regression
        case decision       // architectural or implementation decision
        // Integration-domain
        case haEntity       // Home Assistant entity
        case githubIssue    // GitHub issue
        case githubPR       // GitHub pull request
        // Social-domain
        case device
        case person
        case topic

        var symbol: String {
            switch self {
            case .app:         return "app.badge"
            case .overlay:     return "rectangle.stack"
            case .memory:      return "brain.head.profile"
            case .command:     return "bolt.fill"
            case .website:     return "globe"
            case .project:     return "folder"
            case .repo:        return "chevron.left.forwardslash.chevron.right"
            case .file:        return "doc.text"
            case .feature:     return "star"
            case .bug:         return "ant"
            case .decision:    return "checkmark.seal"
            case .haEntity:    return "house"
            case .githubIssue: return "exclamationmark.circle"
            case .githubPR:    return "arrow.triangle.pull"
            case .device:      return "laptopcomputer"
            case .person:      return "person.fill"
            case .topic:       return "tag"
            }
        }

        var domain: EntityDomain {
            switch self {
            case .app, .overlay, .memory, .command, .website:
                return .ui
            case .project, .repo, .file, .feature, .bug, .decision:
                return .project
            case .haEntity, .githubIssue, .githubPR:
                return .integration
            case .device, .person, .topic:
                return .social
            }
        }
    }

    // MARK: - EntityDomain

    /// Broad grouping that separates UI-layer entities from project/integration entities.
    /// `ActiveContextRegistry` uses `.ui`; Brain retrieval uses `.project` and `.integration`.
    enum EntityDomain: String, Codable, CaseIterable {
        case ui
        case project
        case integration
        case social
    }
}

// MARK: - EntityRelationship

struct EntityRelationship: Identifiable, Codable, Equatable {
    let id: UUID
    let fromID: String
    let toID: String
    let kind: RelationshipKind
    var timestamp: Date
    var confidence: Double  // 0–1

    enum RelationshipKind: String, Codable {
        // UI-domain
        case usedWith        // used in same session / context
        case triggeredBy     // command triggered app/overlay
        case storedIn        // memory stored while using app
        case capturedFrom    // OCR/camera captured in app context
        case openedFrom      // overlay opened from command
        case associatedWith  // loose association
        // Project-domain
        case blocks          // this entity blocks progress on that entity
        case fixes           // commit/PR resolves an issue
        case contradicts     // memory/decision contradicts another
        case dependsOn       // feature or task depends on another
        case supersedes      // newer decision replaces an older one
        case requestedBy     // feature or change requested by person
        case implementedIn   // feature implemented in repo or file
    }

    init(from: String, to: String,
         kind: RelationshipKind,
         confidence: Double = 0.7) {
        self.id = UUID()
        self.fromID = from
        self.toID = to
        self.kind = kind
        self.timestamp = Date()
        self.confidence = confidence
    }
}

// MARK: - EntityGraph

/// Lightweight in-memory entity graph persisted to JSON.
/// Nodes = things Jarvis knows about. Edges = how they relate.
@Observable
@MainActor
final class EntityGraph {

    private(set) var nodes: [String: EntityNode] = [:]
    private(set) var relationships: [EntityRelationship] = []

    private let maxRelationships = 500
    private let persistURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        persistURL = dir.appendingPathComponent("entity_graph.json")
        loadFromDisk()
    }

    // MARK: - Node management

    @discardableResult
    func upsert(id: String, kind: EntityNode.EntityKind, label: String) -> EntityNode {
        if var existing = nodes[id] {
            existing.lastSeen = Date()
            existing.weight = min(1.0, existing.weight + 0.05)
            nodes[id] = existing
            scheduleSave()
            return existing
        }
        let node = EntityNode(id: id, kind: kind, label: label,
                              firstSeen: Date(), lastSeen: Date(), weight: 0.1)
        nodes[id] = node
        scheduleSave()
        return node
    }

    func touch(_ id: String) {
        if var node = nodes[id] {
            node.lastSeen = Date()
            node.weight = min(1.0, node.weight + 0.03)
            nodes[id] = node
        }
    }

    // MARK: - Relationship management

    func relate(from: String, to: String,
                kind: EntityRelationship.RelationshipKind,
                confidence: Double = 0.7) {
        // Strengthen existing relationship if same pair+kind exists
        if let idx = relationships.firstIndex(where: {
            $0.fromID == from && $0.toID == to && $0.kind == kind
        }) {
            relationships[idx].confidence = min(1.0, relationships[idx].confidence + 0.05)
            relationships[idx].timestamp = Date()
        } else {
            relationships.append(EntityRelationship(from: from, to: to,
                                                    kind: kind,
                                                    confidence: confidence))
        }
        trim()
        scheduleSave()
    }

    // MARK: - Queries

    func relationships(from id: String) -> [EntityRelationship] {
        relationships.filter { $0.fromID == id || $0.toID == id }
    }

    func neighbours(of id: String) -> [EntityNode] {
        let rels = relationships(from: id)
        let ids = rels.flatMap { [$0.fromID, $0.toID] }.filter { $0 != id }
        return ids.compactMap { nodes[$0] }
    }

    func topNodes(limit: Int = 20) -> [EntityNode] {
        Array(nodes.values.sorted { $0.weight > $1.weight }.prefix(limit))
    }

    /// Resolve entity ID for EntityResolver usage in IntentRouter.
    func resolve(label: String, kind: EntityNode.EntityKind? = nil) -> EntityNode? {
        let q = label.lowercased()
        return nodes.values.first {
            (kind == nil || $0.kind == kind) &&
            $0.label.lowercased().contains(q)
        }
    }

    // MARK: - Convenience builders

    func recordAppOpen(_ appName: String) {
        let id = "app:\(appName)"
        upsert(id: id, kind: .app, label: appName)
    }

    func recordCommand(_ text: String, appName: String) {
        let cmdID = "cmd:\(text.prefix(40))"
        let appID = "app:\(appName)"
        upsert(id: cmdID, kind: .command, label: String(text.prefix(40)))
        if !appName.isEmpty {
            upsert(id: appID, kind: .app, label: appName)
            relate(from: cmdID, to: appID, kind: .usedWith)
        }
    }

    func recordMemory(_ memoryID: String, appName: String) {
        let memID = "memory:\(memoryID)"
        let appID = "app:\(appName)"
        upsert(id: memID, kind: .memory, label: "Memory")
        if !appName.isEmpty {
            upsert(id: appID, kind: .app, label: appName)
            relate(from: memID, to: appID, kind: .storedIn)
        }
    }

    func recordOverlayOpen(_ overlayName: String, triggeredBy cmdID: String?) {
        let ovID = "overlay:\(overlayName)"
        upsert(id: ovID, kind: .overlay, label: overlayName)
        if let cmdID {
            relate(from: cmdID, to: ovID, kind: .openedFrom)
        }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var nodes: [EntityNode]
        var relationships: [EntityRelationship]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        let payload = Payload(nodes: Array(nodes.values),
                              relationships: Array(relationships.suffix(300)))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(payload) {
            try? data.write(to: persistURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: persistURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let payload = try? dec.decode(Payload.self, from: data) else { return }
        nodes = Dictionary(uniqueKeysWithValues: payload.nodes.map { ($0.id, $0) })
        relationships = payload.relationships
    }

    private func trim() {
        if relationships.count > maxRelationships {
            // Remove lowest-confidence oldest relationships
            relationships = relationships
                .sorted { $0.confidence > $1.confidence }
                .prefix(maxRelationships)
                .sorted { $0.timestamp < $1.timestamp }
        }
    }
}
