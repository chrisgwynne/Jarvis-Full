import Foundation

// MARK: - SystemEvent Protocol

protocol SystemEvent: Sendable {
    var id: UUID { get }
    var timestamp: Date { get }
    var source: SystemEventSource { get }
    var category: SystemEventCategory { get }
    var priority: SystemEventPriority { get }
    var correlationID: UUID? { get }
}

enum SystemEventSource: String, Sendable, Codable {
    case ambient        = "ambient"
    case screen         = "screen"
    case speech         = "speech"
    case overlay        = "overlay"
    case memory         = "memory"
    case proactivity    = "proactivity"
    case android        = "android"
    case github         = "github"
    case system         = "system"
    case user           = "user"
    case homeAssistant  = "home_assistant"
}

enum SystemEventCategory: String, Sendable, Codable {
    case app            = "app"
    case screen         = "screen"
    case speech         = "speech"
    case overlay        = "overlay"
    case memory         = "memory"
    case proactivity    = "proactivity"
    case device         = "device"
    case ci             = "ci"
    case system         = "system"
    case privacy        = "privacy"
}

enum SystemEventPriority: Int, Sendable, Comparable, Codable {
    case low      = 0
    case normal   = 1
    case high     = 2
    case urgent   = 3
    case critical = 4

    static func < (lhs: SystemEventPriority, rhs: SystemEventPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - SystemBus

/// Lightweight @MainActor pub/sub bus. All events are dispatched synchronously
/// on the main actor — no background queues, no Combine, no heavy framework.
///
/// Publish from any MainActor context:
///   SystemBus.shared.publish(AppFocusChangedEvent(...))
///
/// From a background task, hop first:
///   Task { @MainActor in SystemBus.shared.publish(event) }
@MainActor
final class SystemBus {

    static let shared = SystemBus()

    // MARK: - Subscription token

    struct SubscriptionToken: Hashable {
        let id: UUID
        init() { self.id = UUID() }
    }

    // MARK: - Internal subscription record

    private struct Subscription {
        let token: SubscriptionToken
        let typeID: ObjectIdentifier
        let handler: (any SystemEvent) -> Void
    }

    private var subscriptions: [Subscription] = []

    // MARK: - Recursion protection
    // Prevents event-storm infinite loops when a handler publishes during dispatch.

    private var publishDepth = 0
    private let maxPublishDepth = 5

    // MARK: - Recent event ring buffer

    private(set) var recentEvents: [any SystemEvent] = []
    private let maxRecentEvents = 200

    // MARK: - Subscribe

    @discardableResult
    func subscribe<E: SystemEvent>(
        _ type: E.Type,
        handler: @escaping @MainActor (E) -> Void
    ) -> SubscriptionToken {
        let token = SubscriptionToken()
        subscriptions.append(Subscription(
            token: token,
            typeID: ObjectIdentifier(type),
            handler: { event in
                guard let typed = event as? E else { return }
                handler(typed)
            }
        ))
        return token
    }

    func unsubscribe(_ token: SubscriptionToken) {
        subscriptions.removeAll { $0.token == token }
    }

    // MARK: - Publish

    func publish<E: SystemEvent>(_ event: E) {
        // Recursion guard: a handler publishing during dispatch would recurse indefinitely.
        // Drop events beyond depth 5 and log a warning so we can diagnose the source.
        guard publishDepth < maxPublishDepth else {
            Log.app.warning("[SystemBus] publish depth \(self.publishDepth) exceeded for \(String(describing: E.self)) — event dropped to prevent recursion")
            return
        }
        publishDepth += 1
        defer { publishDepth -= 1 }

        // Append to ring buffer
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - maxRecentEvents)
        }

        // Dispatch to type-matched subscribers
        let typeID = ObjectIdentifier(E.self)
        for sub in subscriptions where sub.typeID == typeID {
            sub.handler(event)
        }

        // Dispatch to catch-all subscribers
        for (_, handler) in catchAllSubscriptions {
            handler(event)
        }
    }

    // MARK: - Convenience queries

    func recentEvents<E: SystemEvent>(of type: E.Type, limit: Int = 20) -> [E] {
        recentEvents
            .compactMap { $0 as? E }
            .prefix(limit)
            .map { $0 }
    }

    func recentEvents(category: SystemEventCategory, limit: Int = 50) -> [any SystemEvent] {
        recentEvents
            .filter { $0.category == category }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Catch-all subscription (for EventStore)

    private var catchAllSubscriptions: [(SubscriptionToken, (any SystemEvent) -> Void)] = []

    @discardableResult
    func subscribeAll(handler: @escaping @MainActor (any SystemEvent) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        catchAllSubscriptions.append((token, handler))
        return token
    }

    func unsubscribeCatchAll(_ token: SubscriptionToken) {
        catchAllSubscriptions.removeAll { $0.0 == token }
    }
}
