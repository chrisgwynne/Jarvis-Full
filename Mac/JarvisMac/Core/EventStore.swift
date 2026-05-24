import Foundation

// MARK: - StoredEvent

/// Type-erased wrapper so EventStore can hold heterogeneous SystemEvent values.
struct StoredEvent: Sendable {
    let id: UUID
    let timestamp: Date
    let source: SystemEventSource
    let category: SystemEventCategory
    let priority: SystemEventPriority
    let correlationID: UUID?
    let typeName: String
    let erased: any SystemEvent

    init(_ event: any SystemEvent) {
        self.id = event.id
        self.timestamp = event.timestamp
        self.source = event.source
        self.category = event.category
        self.priority = event.priority
        self.correlationID = event.correlationID
        self.typeName = String(describing: type(of: event))
        self.erased = event
    }
}

// MARK: - EventStore

/// Queryable, bounded ring buffer of all SystemBus events.
/// Subscribes to every event via `subscribeAll`. Provides filtering
/// by category, time window, source, priority, and type name.
/// Used by RuntimeDiagnosticsOverlay and TaskThreadEngine.
@MainActor
final class EventStore {

    static let shared = EventStore()

    private let capacity: Int
    private var buffer: [StoredEvent] = []
    private var busToken: SystemBus.SubscriptionToken?

    var count: Int { buffer.count }

    init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    // MARK: - Lifecycle

    func start() {
        guard busToken == nil else { return }
        busToken = SystemBus.shared.subscribeAll { [weak self] event in
            self?.ingest(event)
        }
    }

    func stop() {
        if let token = busToken {
            SystemBus.shared.unsubscribeCatchAll(token)
            busToken = nil
        }
    }

    // MARK: - Ingestion

    private func ingest(_ event: any SystemEvent) {
        buffer.append(StoredEvent(event))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    // MARK: - Queries

    func all(limit: Int = 100) -> [StoredEvent] {
        Array(buffer.suffix(limit).reversed())
    }

    func events(category: SystemEventCategory, limit: Int = 50) -> [StoredEvent] {
        buffer.filter { $0.category == category }.suffix(limit).reversed().map { $0 }
    }

    func events(source: SystemEventSource, limit: Int = 50) -> [StoredEvent] {
        buffer.filter { $0.source == source }.suffix(limit).reversed().map { $0 }
    }

    func events(priority: SystemEventPriority, limit: Int = 50) -> [StoredEvent] {
        buffer.filter { $0.priority >= priority }.suffix(limit).reversed().map { $0 }
    }

    func events(since date: Date, limit: Int = 200) -> [StoredEvent] {
        buffer.filter { $0.timestamp >= date }.suffix(limit).reversed().map { $0 }
    }

    func events(typeName: String, limit: Int = 50) -> [StoredEvent] {
        buffer.filter { $0.typeName == typeName }.suffix(limit).reversed().map { $0 }
    }

    func events(correlationID: UUID) -> [StoredEvent] {
        buffer.filter { $0.correlationID == correlationID }.map { $0 }
    }

    func typed<E: SystemEvent>(_ type: E.Type, limit: Int = 50) -> [E] {
        buffer.compactMap { $0.erased as? E }.suffix(limit).reversed().map { $0 }
    }

    // MARK: - Diagnostics

    /// Count of events per category in the last N seconds.
    func throughput(windowSeconds: TimeInterval = 60.0) -> [SystemEventCategory: Int] {
        let cutoff = Date(timeIntervalSinceNow: -windowSeconds)
        var counts: [SystemEventCategory: Int] = [:]
        for event in buffer where event.timestamp >= cutoff {
            counts[event.category, default: 0] += 1
        }
        return counts
    }

    func clear() {
        buffer.removeAll()
    }
}
