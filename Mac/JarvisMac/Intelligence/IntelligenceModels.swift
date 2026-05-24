import Foundation

// MARK: - ImplementationStatus

/// The implementation state of a Jarvis feature or subsystem.
enum ImplementationStatus: String, Codable, CaseIterable {
    case implemented = "implemented"
    case partial     = "partial"
    case stubbed     = "stubbed"
    case broken      = "broken"
    case planned     = "planned"
    case unknown     = "unknown"

    var humanLabel: String {
        switch self {
        case .implemented: return "implemented"
        case .partial:     return "partially implemented"
        case .stubbed:     return "stubbed but not fully wired"
        case .broken:      return "broken"
        case .planned:     return "planned but not started"
        case .unknown:     return "status unknown"
        }
    }

    var confidence: Double {
        switch self {
        case .implemented: return 0.90
        case .partial:     return 0.75
        case .stubbed:     return 0.70
        case .broken:      return 0.85
        case .planned:     return 0.80
        case .unknown:     return 0.30
        }
    }
}

// MARK: - FeatureNode

/// A structured record of a Jarvis feature with implementation state and metadata.
struct FeatureNode: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var aliases: [String] = []
    var files: [String] = []
    var status: ImplementationStatus = .unknown
    var summary: String = ""
    var knownIssues: [String] = []
    var dependencies: [String] = []
    var relatedSettings: [String] = []
    var relatedTests: [String] = []
    var notes: [String] = []
    var lastUpdated: Date = Date()
}

// MARK: - CodeChunk

/// A chunk of code or documentation for semantic retrieval.
struct CodeChunk: Identifiable, Codable {
    var id: UUID = UUID()
    var filePath: String
    var language: ChunkLanguage
    var symbolName: String?
    var content: String
    var summary: String
    var startLine: Int = 0
    var endLine: Int = 0
    var lastModified: Date = Date()
    var relatedFeatures: [String] = []

    enum ChunkLanguage: String, Codable {
        case swift, markdown, json, kotlin, other
    }

    var displayPath: String {
        filePath.components(separatedBy: "/").suffix(2).joined(separator: "/")
    }
}

// MARK: - SelfQueryResult

/// Result from JarvisSelfQueryService for a user question about Jarvis itself.
struct SelfQueryResult {
    let query: String
    let relevantFeatures: [FeatureNode]
    let relevantChunks: [CodeChunk]
    let implementationState: ImplementationStatus?
    let suggestedAnswer: String
    let confidence: Double
    let sources: [String]

    var isEmpty: Bool {
        relevantFeatures.isEmpty && relevantChunks.isEmpty
    }
}

// MARK: - DialogueTurn

/// Normalized conversational object representing one rich turn in the dialogue.
/// Distinct from the lighter-weight `ConversationTurn` in `ConversationMemoryStore`
/// which is used for session persistence.
struct DialogueTurn: Identifiable, Sendable {
    let id: UUID
    let role: Role
    let rawTranscript: String
    let cleanedTranscript: String
    let timestamp: Date
    let intentLabel: String?
    let extractedEntities: [String]
    let activeTopic: String?
    let emotionalTone: EmotionalTone
    let route: ConversationRoute?
    let toolsExecuted: [String]
    let wasInterruption: Bool

    enum Role: String, Sendable { case user, assistant }

    enum EmotionalTone: String, Sendable {
        case neutral, frustrated, excited, stressed, tired, curious
    }

    var ageSeconds: Double { Date().timeIntervalSince(timestamp) }
    var isRecent: Bool { ageSeconds < 300 }
}
