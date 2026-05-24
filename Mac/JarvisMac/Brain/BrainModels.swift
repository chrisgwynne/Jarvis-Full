import Foundation

// MARK: - BrainMemorySource

/// Where a BrainMemory (MemoryCandidate committed to BrainMemoryStore) originated.
enum BrainMemorySource: String, Codable, Sendable, CaseIterable {
    case conversation       // general voice exchange
    case voiceCommand       // explicit "remember that…" utterance
    case memoryExtractor    // auto-extracted by MemoryExtractor
    case github             // GitHubBrainBridge
    case homeAssistant      // HABrainBridge
    case obsidian           // ObsidianVaultService
    case projectDocs        // FEATURES/TODO/CLAUDE.md keyword scan
    case commandHistory     // succeeded / failed command log
    case userEdited         // user manually created or corrected in UI
    case dreamCycle         // synthesised during idle maintenance
}

// MARK: - BrainPrivacyLevel

/// Controls where a memory may appear.
enum BrainPrivacyLevel: String, Codable, Sendable {
    /// Default — full-text searchable, injectable into LLM context.
    case normal
    /// Stored but never injected into LLM prompts or exported.
    case sensitive
    /// Excluded from semantic index, search export, and LLM context; local storage only.
    case `private`
}

// MARK: - BrainTaskType

enum BrainTaskType: String, Codable, Sendable, CaseIterable {
    case repoAudit
    case githubIssueScan
    case memoryConsolidation
    case fileIndexing
    case haEntityRefresh
    case uiHealthAudit
    case failedCommandReview
    case episodeSummarisation
    case dreamCycle
    case custom

    var displayName: String {
        switch self {
        case .repoAudit:            return "Repo Audit"
        case .githubIssueScan:      return "GitHub Issue Scan"
        case .memoryConsolidation:  return "Memory Consolidation"
        case .fileIndexing:         return "File Indexing"
        case .haEntityRefresh:      return "HA Entity Refresh"
        case .uiHealthAudit:        return "UI Health Audit"
        case .failedCommandReview:  return "Failed Command Review"
        case .episodeSummarisation: return "Episode Summarisation"
        case .dreamCycle:           return "Dream Cycle"
        case .custom:               return "Custom Task"
        }
    }
}

// MARK: - BrainTaskStatus

enum BrainTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case paused
    case failed
    case completed
    case cancelled

    var isTerminal: Bool { self == .failed || self == .completed || self == .cancelled }
    var isActive:   Bool { self == .queued || self == .running   || self == .paused    }

    var icon: String {
        switch self {
        case .queued:    return "⏳"
        case .running:   return "▶"
        case .paused:    return "⏸"
        case .failed:    return "✗"
        case .completed: return "✓"
        case .cancelled: return "⊘"
        }
    }
}

// MARK: - BrainTask

/// A durable, restart-safe unit of background work owned by BrainTaskQueue.
struct BrainTask: Identifiable, Codable, Sendable {
    var id: String              = UUID().uuidString
    var title: String
    var type: BrainTaskType
    var status: BrainTaskStatus = .queued
    /// Priority 1 (highest) – 10 (lowest). Default 5 = normal.
    var priority: Int           = 5
    var createdAt: Date         = Date()
    var startedAt: Date?
    var completedAt: Date?
    var error: String?
    var retryCount: Int         = 0
    var maxRetries: Int         = 3
    /// Arbitrary JSON payload interpreted by the worker.
    var payloadJSON: String     = "{}"
    /// 0.0 – 1.0 completion fraction for progress UI.
    var progress: Double        = 0.0
    /// Show in user-facing task tray.
    var userVisible: Bool       = false
    var tags: [String]          = []
}

// MARK: - EpisodeType

enum EpisodeType: String, Codable, Sendable, CaseIterable {
    case development
    case debugging
    case planning
    case research
    case conversation
    case homeAssistant
    case github
    case system
    case general

    var displayName: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .development:  return "hammer"
        case .debugging:    return "ant"
        case .planning:     return "calendar"
        case .research:     return "magnifyingglass"
        case .conversation: return "bubble.left.and.bubble.right"
        case .homeAssistant: return "house"
        case .github:       return "chevron.left.forwardslash.chevron.right"
        case .system:       return "gear"
        case .general:      return "doc.text"
        }
    }
}

// MARK: - ConversationEpisode

/// A time-bounded grouping of related memories, commands, and entities.
/// Auto-generated from activity bursts; may be manually named by the user.
struct ConversationEpisode: Identifiable, Codable, Sendable {
    var id: String               = UUID().uuidString
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var summary: String          = ""
    var relatedMemoryIds: [String]  = []
    var relatedEntityIds: [String]  = []
    var dominantTopics: [String]    = []
    var dominantProjects: [String]  = []
    var dominantApps: [String]      = []
    var tags: [String]              = []
    /// 0.0–1.0 significance weight for retrieval ranking.
    var importance: Double       = 0.5
    var episodeType: EpisodeType = .general
    var userInitiated: Bool      = false

    var durationMinutes: Double? {
        guard let ended = endedAt else { return nil }
        return ended.timeIntervalSince(startedAt) / 60
    }
}

// MARK: - SystemBus event types

/// Published whenever a memory is committed to BrainMemoryStore.
struct BrainMemoryWrittenEvent: SystemEvent {
    let base: SystemEventBase
    let memoryId: String
    let memoryType: String
    let memorySource: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .memory }
    var category: SystemEventCategory { .memory }
    var priority: SystemEventPriority { .low }

    init(memoryId: String, memoryType: String, memorySource: String) {
        self.base         = SystemEventBase()
        self.memoryId     = memoryId
        self.memoryType   = memoryType
        self.memorySource = memorySource
    }
}

/// Published when a task is added to BrainTaskQueue.
struct BrainTaskQueuedEvent: SystemEvent {
    let base: SystemEventBase
    let taskId: String
    let taskType: String
    let taskTitle: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .low }

    init(taskId: String, taskType: String, taskTitle: String) {
        self.base      = SystemEventBase()
        self.taskId    = taskId
        self.taskType  = taskType
        self.taskTitle = taskTitle
    }
}

/// Published when a task's status changes (running, completed, failed, …).
struct BrainTaskStatusChangedEvent: SystemEvent {
    let base: SystemEventBase
    let taskId: String
    let newStatus: String
    let taskTitle: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .normal }

    init(taskId: String, newStatus: String, taskTitle: String) {
        self.base      = SystemEventBase()
        self.taskId    = taskId
        self.newStatus = newStatus
        self.taskTitle = taskTitle
    }
}

/// Published when an episode begins.
struct BrainEpisodeStartedEvent: SystemEvent {
    let base: SystemEventBase
    let episodeId: String
    let episodeTitle: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .memory }
    var category: SystemEventCategory { .memory }
    var priority: SystemEventPriority { .low }

    init(episodeId: String, episodeTitle: String) {
        self.base         = SystemEventBase()
        self.episodeId    = episodeId
        self.episodeTitle = episodeTitle
    }
}

/// Published when an episode ends and its summary is written.
struct BrainEpisodeEndedEvent: SystemEvent {
    let base: SystemEventBase
    let episodeId: String
    let memoryCount: Int
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .memory }
    var category: SystemEventCategory { .memory }
    var priority: SystemEventPriority { .low }

    init(episodeId: String, memoryCount: Int) {
        self.base        = SystemEventBase()
        self.episodeId   = episodeId
        self.memoryCount = memoryCount
    }
}
