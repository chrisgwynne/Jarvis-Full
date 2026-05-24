import Foundation

// MARK: - Edge Type

enum ContextEdgeType: String, Codable, Hashable, CaseIterable {
    case relatesTo
    case mentions
    case causedBy
    case blockedBy
    case continues
    case references
    case createdFrom
    case belongsToProject
    case sameTopicAs
    case recentlyUsedWith
    case followedBy

    var displayName: String {
        switch self {
        case .relatesTo:         return "relates to"
        case .mentions:          return "mentions"
        case .causedBy:          return "caused by"
        case .blockedBy:         return "blocked by"
        case .continues:         return "continues"
        case .references:        return "references"
        case .createdFrom:       return "created from"
        case .belongsToProject:  return "belongs to project"
        case .sameTopicAs:       return "same topic as"
        case .recentlyUsedWith:  return "recently used with"
        case .followedBy:        return "followed by"
        }
    }
}

// MARK: - Edge

struct ContextEdge: Identifiable, Codable, Hashable {

    let id: UUID
    /// The source node's ID.
    let from: UUID
    /// The destination node's ID.
    let to: UUID
    let type: ContextEdgeType
    var confidence: Double
    let createdAt: Date
    /// Human-readable explanation for why this edge exists.
    var evidence: String?
    let source: ContextSource

    init(
        from: UUID,
        to: UUID,
        type: ContextEdgeType,
        confidence: Double = 0.8,
        evidence: String? = nil,
        source: ContextSource = .system
    ) {
        self.id         = UUID()
        self.from       = from
        self.to         = to
        self.type       = type
        self.confidence = min(max(confidence, 0), 1)
        self.createdAt  = Date()
        self.evidence   = evidence
        self.source     = source
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(from)
        hasher.combine(to)
        hasher.combine(type)
    }

    static func == (lhs: ContextEdge, rhs: ContextEdge) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to && lhs.type == rhs.type
    }
}
