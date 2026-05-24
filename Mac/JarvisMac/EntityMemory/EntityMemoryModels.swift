import Foundation

// MARK: - EntityMemKind

enum EntityMemKind: String, Codable, CaseIterable {
    case person
    case repository
    case pullRequest
    case githubIssue
    case branch
    case file
    case folder
    case task
    case meeting
    case uiElement
    case window
    case browserTab
    case url
    case device
    case room
    case conversationTopic
    case automationAction
    case ocrRegion
    case guidanceTarget
    case homeAssistantEntity
    case calendarEvent
    case newsTopic
    case genericConcept

    var halfLifeSeconds: Double {
        switch self {
        case .uiElement, .ocrRegion, .guidanceTarget: return 300
        case .window, .browserTab:                   return 1_800
        case .conversationTopic, .genericConcept:    return 3_600
        case .file, .folder, .branch:                return 86_400
        case .pullRequest, .githubIssue, .task,
             .calendarEvent:                         return 259_200
        case .repository, .homeAssistantEntity,
             .room, .device:                         return 604_800
        case .person, .newsTopic, .url:              return 172_800
        case .meeting:                               return 7_200
        case .automationAction:                      return 86_400
        }
    }

    var defaultExpiryPolicy: ExpiryPolicy {
        switch self {
        case .uiElement, .ocrRegion, .guidanceTarget:
            return .ephemeral
        case .window, .browserTab, .conversationTopic:
            return .session
        case .file, .branch, .task, .meeting, .calendarEvent,
             .automationAction, .newsTopic, .genericConcept:
            return .workflow
        case .folder, .pullRequest, .githubIssue, .repository,
             .url, .person, .homeAssistantEntity, .room, .device:
            return .persistent
        }
    }
}

// MARK: - ExpiryPolicy

enum ExpiryPolicy: String, Codable {
    case ephemeral   // 5 min of no reference
    case session     // 1 hr — expires with conversation session
    case workflow    // 3 days — survives sessions until task complete
    case persistent  // 30 days — long-lived, survives restarts

    var maxAgeSeconds: Double {
        switch self {
        case .ephemeral:  return 300
        case .session:    return 3_600
        case .workflow:   return 86_400 * 3
        case .persistent: return 86_400 * 30
        }
    }
}

// MARK: - EntitySource

enum EntitySource: String, Codable {
    case conversation       // extracted from speech
    case windowsPresence    // from Windows sidecar presence
    case macPresence        // from Mac ambient context
    case githubAPI          // from GitHub notifications/API
    case calendarEvent      // from EventKit
    case todoistTask        // from Todoist
    case homeAssistant      // from HA state
    case ocrExtraction      // from camera/screen OCR
    case userExplicit       // user directly named or described
    case workflowInference  // inferred from workflow context
    case proactiveEvent     // surfaced via proactivity system
}

// MARK: - EntityMemNode

struct EntityMemNode: Identifiable, Codable {
    let id: String
    var entityKind: EntityMemKind
    var canonicalName: String
    var aliases: [String]
    var source: EntitySource
    var createdAt: Date
    var lastMentionedAt: Date
    var lastReferencedAt: Date
    var mentionCount: Int
    var salience: Double        // 0–1, managed by EntitySalienceEngine
    var associatedDevices: [String]
    var associatedApps: [String]
    var associatedUrls: [String]
    var expiryPolicy: ExpiryPolicy
    var metadata: [String: String]

    init(
        entityKind: EntityMemKind,
        canonicalName: String,
        aliases: [String] = [],
        source: EntitySource,
        expiryPolicy: ExpiryPolicy? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = UUID().uuidString
        self.entityKind = entityKind
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.source = source
        self.createdAt = Date()
        self.lastMentionedAt = Date()
        self.lastReferencedAt = Date()
        self.mentionCount = 1
        self.salience = 0.5
        self.associatedDevices = []
        self.associatedApps = []
        self.associatedUrls = []
        self.expiryPolicy = expiryPolicy ?? entityKind.defaultExpiryPolicy
        self.metadata = metadata
    }

    var isExpired: Bool {
        Date().timeIntervalSince(lastReferencedAt) > expiryPolicy.maxAgeSeconds
    }

    func currentRecencyScore() -> Double {
        let age = Date().timeIntervalSince(lastMentionedAt)
        return pow(0.5, age / entityKind.halfLifeSeconds)
    }

    func relevanceScore() -> Double {
        let recency = currentRecencyScore()
        let mentionBonus = min(Double(mentionCount) / 10.0, 0.3)
        return min(salience * 0.5 + recency * 0.4 + mentionBonus, 1.0)
    }
}

// MARK: - EntityMemRelationship

struct EntityMemRelationship: Codable {
    let fromId: String
    let toId: String
    let kind: String       // "mentions", "openedIn", "linkedTo", "partOf", "assignedTo"
    let createdAt: Date
}

// MARK: - ResolutionResult

struct ResolutionResult {
    let entity: EntityMemNode?
    let confidence: Double
    let source: String           // "exact", "alias", "recency", "salience", "heuristic"
    let candidates: [EntityMemNode]
    let needsClarification: Bool
    let clarificationPrompt: String?

    static let empty = ResolutionResult(
        entity: nil, confidence: 0, source: "none",
        candidates: [], needsClarification: false, clarificationPrompt: nil
    )
}

// MARK: - ReferencePhrase

struct ReferencePhrase {
    let text: String
    let kind: ReferencePhraseKind
}

enum ReferencePhraseKind {
    case pronoun      // "it", "that", "this"
    case recency      // "the other one", "the last one", "that thing"
    case deictic      // "the button", "that field", "the window"
    case continual    // "continue", "keep going", "do that again"
    case crossDevice  // "on Windows", "from the other machine"
}
