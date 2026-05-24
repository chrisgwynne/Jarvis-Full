import Foundation

// MARK: - RuntimeState

/// The lifecycle state of a single subsystem.
enum RuntimeState: String, Sendable, Equatable, CaseIterable {
    case stopped   = "stopped"
    case starting  = "starting"
    case running   = "running"
    case degraded  = "degraded"
    case failed    = "failed"

    var isOperational: Bool {
        self == .running || self == .degraded
    }

    var icon: String {
        switch self {
        case .stopped:  return "⏹"
        case .starting: return "⏳"
        case .running:  return "✅"
        case .degraded: return "⚠️"
        case .failed:   return "❌"
        }
    }

    var displayName: String { rawValue.capitalized }
}

// MARK: - HealthStatus

enum HealthStatus: Equatable, Sendable {
    case healthy
    case degraded(String)   // reason string
    case failed(String)     // reason string

    var isOK: Bool {
        if case .healthy = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var reason: String? {
        switch self {
        case .healthy:          return nil
        case .degraded(let r):  return r
        case .failed(let r):    return r
        }
    }

    var icon: String {
        switch self {
        case .healthy:    return "✅"
        case .degraded:   return "⚠️"
        case .failed:     return "❌"
        }
    }
}

// MARK: - RuntimeSubsystem

/// Every major system that JarvisController owns conforms to this protocol.
/// Conforming types form the single source of truth for a subsystem's lifecycle.
///
/// Design rules:
/// - One conforming class per major responsibility (audio, memory, overlay, etc.)
/// - Thin shells: delegate to existing services, don't duplicate logic
/// - Health checks must be cheap — no network, no heavy compute
/// - Recovery is isolated: a failing subsystem restarts itself, not everything
@MainActor
protocol RuntimeSubsystem: AnyObject {
    /// Stable machine-readable identifier (e.g. "audio", "memory")
    var id: String { get }
    /// Human-readable name for UI display
    var displayName: String { get }
    /// Current lifecycle state
    var state: RuntimeState { get }
    /// Lower number = starts earlier. Gap between tiers is intentional
    /// so new subsystems can slot in without renumbering.
    var startupOrder: Int { get }
    /// True if this subsystem can be restarted without a full-app restart
    var canRecoverIndependently: Bool { get }

    func start() async throws
    func stop() async
    func healthCheck() async -> HealthStatus
    func recover() async throws
}

extension RuntimeSubsystem {
    var canRecoverIndependently: Bool { true }

    func recover() async throws {
        await stop()
        try await start()
    }
}

// MARK: - SystemEvent: RuntimeReadyEvent

/// Published to SystemBus when RuntimeCoordinator transitions to .ready.
struct RuntimeReadyEvent: SystemEvent {
    let base = SystemEventBase()
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .normal }
}

/// Published when a subsystem recovers from failure.
struct SubsystemRecoveredEvent: SystemEvent {
    let base: SystemEventBase
    let subsystemID: String
    let attemptCount: Int
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .normal }

    init(subsystemID: String, attemptCount: Int) {
        self.base = SystemEventBase()
        self.subsystemID = subsystemID
        self.attemptCount = attemptCount
    }
}

/// Published when a subsystem fails and cannot recover.
struct SubsystemFailedEvent: SystemEvent {
    let base: SystemEventBase
    let subsystemID: String
    let reason: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .urgent }

    init(subsystemID: String, reason: String) {
        self.base = SystemEventBase()
        self.subsystemID = subsystemID
        self.reason = reason
    }
}
