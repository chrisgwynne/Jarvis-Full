import Foundation

// MARK: - LivingSystemID

/// The non-core, editable runtime layers that define Jarvis. Each maps to a
/// concrete backing store (a PersonalityFileStore file, the HeartbeatStore, or a
/// generic LiveDocStore) wired up in `LivingSystemRegistry.configure`.
enum LivingSystemID: String, Codable, CaseIterable, Sendable {
    case soul
    case identity
    case voice
    case userModel
    case behaviourRules
    case responseRules
    case boundaries
    case heartbeat
    case commands
    case goals
    case skills
    case agents
    case memoryRules
    case projectState

    var displayName: String {
        switch self {
        case .soul:           return "Soul"
        case .identity:       return "Identity"
        case .voice:          return "Voice"
        case .userModel:      return "User Model"
        case .behaviourRules: return "Behaviour Rules"
        case .responseRules:  return "Response Rules"
        case .boundaries:     return "Boundaries"
        case .heartbeat:      return "Heartbeat"
        case .commands:       return "Commands"
        case .goals:          return "Goals"
        case .skills:         return "Skills"
        case .agents:         return "Agents"
        case .memoryRules:    return "Memory Rules"
        case .projectState:   return "Project State"
        }
    }

    /// The header used when this system is injected into the LLM context.
    var contextLabel: String { displayName.uppercased() }
}

// MARK: - RiskLevel

enum RiskLevel: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high
    case protectedCore

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .protectedCore: return 3
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }
}

// MARK: - EditSource

/// Who/what initiated an edit. `userApproved` is the only source permitted to
/// apply changes to protected-core systems.
enum EditSource: String, Codable, Sendable {
    case user
    case userApproved
    case jarvis
    case system
    case commandFailure
}

// MARK: - ValidationResult

enum ValidationResult: Equatable {
    case valid
    case invalid(String)
    case needsApproval(String)

    var isValid: Bool { if case .valid = self { return true } else { return false } }

    var reason: String? {
        switch self {
        case .valid: return nil
        case .invalid(let r), .needsApproval(let r): return r
        }
    }
}

// MARK: - RuntimePatch

/// A safe, reversible record of a single change to a living system.
struct RuntimePatch: Identifiable, Codable, Equatable {
    let id: UUID
    let systemID: String
    let before: String
    let after: String
    let reason: String
    let source: EditSource
    let timestamp: Date
    let risk: RiskLevel
    var applied: Bool
    /// If this patch reverses another, the id of the patch it undid.
    let rollbackRef: UUID?

    init(id: UUID = UUID(),
         systemID: String,
         before: String,
         after: String,
         reason: String,
         source: EditSource,
         timestamp: Date = Date(),
         risk: RiskLevel,
         applied: Bool,
         rollbackRef: UUID? = nil) {
        self.id = id
        self.systemID = systemID
        self.before = before
        self.after = after
        self.reason = reason
        self.source = source
        self.timestamp = timestamp
        self.risk = risk
        self.applied = applied
        self.rollbackRef = rollbackRef
    }
}

// MARK: - AuditEntry

/// A persistent, human-readable record of every attempted runtime edit.
struct AuditEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let systemID: String
    /// "applied" | "rejected" | "proposed" | "rolled_back"
    let action: String
    let summary: String
    let beforePreview: String
    let afterPreview: String
    let source: EditSource
    let risk: RiskLevel
    let rollbackAvailable: Bool
    let patchID: UUID?

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         systemID: String,
         action: String,
         summary: String,
         beforePreview: String,
         afterPreview: String,
         source: EditSource,
         risk: RiskLevel,
         rollbackAvailable: Bool,
         patchID: UUID?) {
        self.id = id
        self.timestamp = timestamp
        self.systemID = systemID
        self.action = action
        self.summary = summary
        self.beforePreview = beforePreview
        self.afterPreview = afterPreview
        self.source = source
        self.risk = risk
        self.rollbackAvailable = rollbackAvailable
        self.patchID = patchID
    }
}

// MARK: - EditOutcome

enum EditOutcome: Equatable {
    case applied(RuntimePatch)
    case rejected(String)
    case needsApproval(RuntimePatch)
    case noChange

    var patch: RuntimePatch? {
        switch self {
        case .applied(let p), .needsApproval(let p): return p
        default: return nil
        }
    }
}

// MARK: - SystemBus event

/// Published whenever a living system changes so the UI, Brain context, and any
/// observers can react immediately — no restart, no manual refresh.
struct LivingSystemChangedEvent: SystemEvent {
    let base: SystemEventBase
    let systemID: String
    let action: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource     { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .normal }

    init(systemID: String, action: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.systemID = systemID
        self.action = action
    }
}

// MARK: - Preview helper

extension String {
    /// A single-line, length-capped preview for audit display.
    func auditPreview(_ max: Int = 120) -> String {
        let oneLine = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count <= max ? oneLine : String(oneLine.prefix(max)) + "…"
    }
}
