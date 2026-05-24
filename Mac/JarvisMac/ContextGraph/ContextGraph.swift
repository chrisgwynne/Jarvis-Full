import Foundation

/// In-memory directed graph of context nodes and edges.
///
/// This is the raw storage layer — `ProjectRelationshipIndex` is the query layer.
/// ContextGraph does not make any network calls and holds no external references.
@MainActor final class ContextGraph {

    static let shared = ContextGraph()

    // MARK: - Storage

    private(set) var nodesByID:    [UUID: ContextNode]   = [:]
    private(set) var edgesByID:    [UUID: ContextEdge]   = [:]

    /// Reverse index: externalID + type → node UUID (for dedup).
    private var externalIndex: [String: UUID] = [:]
    /// Adjacency index: node UUID → outgoing edge UUIDs.
    private var outEdges:  [UUID: Set<UUID>] = [:]
    /// Adjacency index: node UUID → incoming edge UUIDs.
    private var inEdges:   [UUID: Set<UUID>] = [:]

    private(set) var lastIngestionAt: Date?

    var nodeCount: Int { nodesByID.count }
    var edgeCount: Int { edgesByID.count }

    // MARK: - Node operations

    /// Adds a new node, or updates an existing one if `externalID` matches.
    /// Returns the final node ID (may differ from `node.id` if deduped).
    @discardableResult
    func upsertNode(_ node: ContextNode) -> UUID {
        if let extID = node.externalID {
            let key = Self.externalKey(id: extID, type: node.type)
            if let existing = externalIndex[key] {
                // Update in place — preserve the original UUID so edges stay valid
                nodesByID[existing] = rebuildWithID(node, id: existing)
                return existing
            }
            externalIndex[key] = node.id
        }
        nodesByID[node.id] = node
        return node.id
    }

    func removeNode(id: UUID) {
        guard let node = nodesByID[id] else { return }
        if let extID = node.externalID {
            externalIndex.removeValue(forKey: Self.externalKey(id: extID, type: node.type))
        }
        // Remove all connected edges
        for edgeID in outEdges[id] ?? [] { edgesByID.removeValue(forKey: edgeID) }
        for edgeID in inEdges[id]  ?? [] { edgesByID.removeValue(forKey: edgeID) }
        outEdges.removeValue(forKey: id)
        inEdges.removeValue(forKey: id)
        nodesByID.removeValue(forKey: id)
    }

    func node(for id: UUID) -> ContextNode? { nodesByID[id] }

    func nodes(ofType type: ContextNodeType) -> [ContextNode] {
        nodesByID.values.filter { $0.type == type }
    }

    func findByExternalID(_ externalID: String, type: ContextNodeType) -> ContextNode? {
        guard let uid = externalIndex[Self.externalKey(id: externalID, type: type)] else { return nil }
        return nodesByID[uid]
    }

    // MARK: - Edge operations

    /// Adds an edge. Deduplicates on (from, to, type) — updates confidence if higher.
    @discardableResult
    func upsertEdge(_ edge: ContextEdge) -> UUID {
        // Check for an existing edge with the same semantic key
        if let existingID = outEdges[edge.from]?
            .compactMap({ edgesByID[$0] })
            .first(where: { $0.to == edge.to && $0.type == edge.type })?.id
        {
            if edge.confidence > (edgesByID[existingID]?.confidence ?? 0) {
                edgesByID[existingID]?.confidence = edge.confidence
            }
            return existingID
        }
        edgesByID[edge.id] = edge
        outEdges[edge.from, default: []].insert(edge.id)
        inEdges[edge.to,   default: []].insert(edge.id)
        return edge.id
    }

    func outgoingEdges(from nodeID: UUID) -> [ContextEdge] {
        (outEdges[nodeID] ?? []).compactMap { edgesByID[$0] }
    }

    func incomingEdges(to nodeID: UUID) -> [ContextEdge] {
        (inEdges[nodeID] ?? []).compactMap { edgesByID[$0] }
    }

    func neighbours(of nodeID: UUID) -> [ContextNode] {
        let targets = outgoingEdges(from: nodeID).map(\.to)
            + incomingEdges(to: nodeID).map(\.from)
        return targets.compactMap { nodesByID[$0] }
    }

    // MARK: - Bulk helpers

    func markIngested() { lastIngestionAt = Date() }

    func reset() {
        nodesByID    = [:]
        edgesByID    = [:]
        externalIndex = [:]
        outEdges     = [:]
        inEdges      = [:]
        lastIngestionAt = nil
    }

    // MARK: - Pruning

    /// Removes stale low-value nodes and edges according to `policy`.
    ///
    /// Phase 1 removes old inferred nodes below the confidence floor.
    /// Phase 2 enforces the hard node cap by evicting the lowest-scoring nodes
    /// of any trust tier except `.userEdited` — this is the safety valve that
    /// prevents unbounded growth from `.system` nodes (traces, memories, apps).
    /// Phase 3 enforces the hard edge cap by dropping lowest-confidence edges.
    @discardableResult
    func prune(policy: PrunePolicy = PrunePolicy()) -> PruneResult {
        var nodesRemoved = 0
        var edgesRemoved = 0
        let now = Date()
        let cutoff = now.addingTimeInterval(-policy.maxAgeForInferredDays * 86400)

        // Phase 1: Remove stale inferred nodes (age + low confidence).
        let staleIDs = nodesByID.values
            .filter { $0.trustTier == .inferred
                   && $0.confidence < policy.minConfidenceForInferred
                   && $0.updatedAt < cutoff }
            .map(\.id)
        for id in staleIDs { removeNode(id: id); nodesRemoved += 1 }

        // Phase 2: Hard node cap — evict weakest nodes of any non-protected tier.
        // `.userEdited` nodes are protected (explicit user content).
        // All other tiers (.system, .synced, .inferred) are eligible when over cap.
        if nodesByID.count > policy.maxNodes {
            let excess = nodesByID.count - policy.maxNodes
            let toEvict = nodesByID.values
                .filter { $0.trustTier != .userEdited }
                .sorted { nodeScore($0, now: now) < nodeScore($1, now: now) }
                .prefix(excess)
                .map(\.id)
            for id in toEvict { removeNode(id: id); nodesRemoved += 1 }
        }

        // Phase 3: Hard edge cap — drop lowest-confidence edges.
        if edgesByID.count > policy.maxEdges {
            let excess = edgesByID.count - policy.maxEdges
            let toDrop = edgesByID.values
                .sorted { $0.confidence < $1.confidence }
                .prefix(excess)
            for edge in toDrop {
                edgesByID.removeValue(forKey: edge.id)
                outEdges[edge.from]?.remove(edge.id)
                inEdges[edge.to]?.remove(edge.id)
                edgesRemoved += 1
            }
        }

        return PruneResult(nodesRemoved: nodesRemoved, edgesRemoved: edgesRemoved)
    }

    private func nodeScore(_ node: ContextNode, now: Date) -> Double {
        let ageDays = now.timeIntervalSince(node.updatedAt) / 86400
        let ageFactor = max(0, 1 - ageDays / 30)
        return node.confidence * ageFactor
    }

    // MARK: - Private helpers

    private static func externalKey(id: String, type: ContextNodeType) -> String {
        "\(type.rawValue):\(id)"
    }

    private func rebuildWithID(_ template: ContextNode, id: UUID) -> ContextNode {
        // Swift structs can't mutate 'let' fields; we copy via encode/decode trick or manual rebuild.
        // Since we don't want to change semantics, we keep the original node but update mutable fields.
        var n = nodesByID[id] ?? template
        n.title      = template.title
        n.summary    = template.summary
        n.confidence = max(template.confidence, n.confidence)
        n.updatedAt  = Date()
        if template.trustTier.rawValue < n.trustTier.rawValue {
            n.trustTier = template.trustTier
        }
        return n
    }
}

// MARK: - Prune types

struct PrunePolicy {
    /// Maximum number of nodes before eviction begins.  Keep in sync with ContextGraphPersistence.defaultNodeCap.
    var maxNodes: Int = 600
    /// Maximum number of edges before lowest-confidence edges are dropped.  Keep in sync with ContextGraphPersistence.defaultEdgeCap.
    var maxEdges: Int = 1200
    /// Inferred nodes below this confidence threshold are candidates for removal.
    var minConfidenceForInferred: Double = 0.40
    /// Inferred nodes not updated within this many days are candidates for removal.
    var maxAgeForInferredDays: Double = 14
}

struct PruneResult {
    var nodesRemoved: Int
    var edgesRemoved: Int

    var isEmpty: Bool { nodesRemoved == 0 && edgesRemoved == 0 }
}
