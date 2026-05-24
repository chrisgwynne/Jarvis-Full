import Foundation

// MARK: - EntityType

/// Semantic type of a resolved entity.
enum EntityType: String, Codable, CaseIterable {
    case app
    case contact
    case haDevice
    case haRoom
    case newsChannel
    case youtubeChannel
    case website
    case stream
    case browserBookmark
    case githubRepo
    case appleNote
    case calendarEntity
    case todoistProject
    case shopifyProduct
    case mediaSource
    case customAlias
    case file
    case folder
}

// MARK: - EntityAction

/// Inferred action verb from the transcript.
enum EntityAction: String {
    case open
    case play
    case show
    case send
    case search
    case navigate
    case control
    case create
    case find
    case call
    case unknown
}

// MARK: - EntityCandidate

/// A single entity candidate from one provider, with scoring metadata.
struct EntityCandidate {
    let entityId: String
    let displayName: String
    let entityType: EntityType
    let provider: String
    let aliases: [String]
    let externalURL: URL?
    let bundleIdentifier: String?
    let baseConfidence: Double
    var matchedAlias: String?
    var score: Double = 0
    var matchReason: String = ""
}

// MARK: - EntityResolutionResult

/// Final result returned by EntityFirstResolver for a transcript.
struct EntityResolutionResult {
    let originalSpan: String
    let action: EntityAction
    let entity: EntityCandidate
    let competingCandidates: [EntityCandidate]
    let needsClarification: Bool

    var confidence: Double { entity.score }
    var displayName: String { entity.displayName }
    var entityType: EntityType { entity.entityType }
    var provider: String { entity.provider }
    var matchedAlias: String? { entity.matchedAlias }
    var externalURL: URL? { entity.externalURL }
    var bundleIdentifier: String? { entity.bundleIdentifier }
}

// MARK: - EntityProvider protocol

/// Any source of entity candidates. Providers are lightweight; they return
/// raw candidates and let EntityFirstResolver handle scoring.
protocol EntityProvider {
    var providerName: String { get }
    func candidates(for spans: [String]) async -> [EntityCandidate]
}
