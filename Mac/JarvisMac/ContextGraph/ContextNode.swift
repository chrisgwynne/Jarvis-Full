import Foundation

// MARK: - Node Type

enum ContextNodeType: String, Codable, Hashable, CaseIterable {
    case memory
    case taskThread
    case conversation
    case githubRepo
    case githubIssue
    case githubPR
    case obsidianNote
    case todoistTask
    case calendarEvent
    case executionTrace
    case activeApp
    case project
    case person
    case device
    case appleNote
    case email

    var displayName: String {
        switch self {
        case .memory:         return "Memory"
        case .taskThread:     return "Task Thread"
        case .conversation:   return "Conversation"
        case .githubRepo:     return "Repository"
        case .githubIssue:    return "Issue"
        case .githubPR:       return "Pull Request"
        case .obsidianNote:   return "Note"
        case .todoistTask:    return "Task"
        case .calendarEvent:  return "Event"
        case .executionTrace: return "Trace"
        case .activeApp:      return "App"
        case .project:        return "Project"
        case .person:         return "Person"
        case .device:         return "Device"
        case .appleNote:      return "Apple Note"
        case .email:          return "Email"
        }
    }
}

// MARK: - Trust Tier

/// Describes how trustworthy the information backing a node is.
enum TrustTier: Int, Codable, Comparable, CaseIterable {
    case system    = 0   // Jarvis-generated (execution traces, task threads)
    case synced    = 1   // Authoritative integration (GitHub, Todoist, Calendar)
    case userEdited = 2  // Explicitly created/edited by the user (Obsidian, pinned memory)
    case inferred  = 3   // Derived by pattern-matching or LLM

    static func < (lhs: TrustTier, rhs: TrustTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .system:     return "system"
        case .synced:     return "synced"
        case .userEdited: return "user"
        case .inferred:   return "inferred"
        }
    }
}

// MARK: - Node

struct ContextNode: Identifiable, Codable, Hashable {

    let id: UUID
    let type: ContextNodeType
    var title: String
    var summary: String
    let source: ContextSource
    let createdAt: Date
    var updatedAt: Date
    var confidence: Double      // 0–1
    var trustTier: TrustTier
    var metadata: [String: String]
    /// Stable external identifier for deduplication (e.g. GitHub URL, Obsidian path).
    var externalID: String?

    init(
        type: ContextNodeType,
        title: String,
        summary: String,
        source: ContextSource,
        confidence: Double = 0.8,
        trustTier: TrustTier = .system,
        metadata: [String: String] = [:],
        externalID: String? = nil
    ) {
        self.id         = UUID()
        self.type       = type
        self.title      = title
        self.summary    = summary
        self.source     = source
        self.createdAt  = Date()
        self.updatedAt  = Date()
        self.confidence = min(max(confidence, 0), 1)
        self.trustTier  = trustTier
        self.metadata   = metadata
        self.externalID = externalID
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ContextNode, rhs: ContextNode) -> Bool { lhs.id == rhs.id }
}
