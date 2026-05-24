import Foundation
import OSLog

private let watchdogLogger = Logger(subsystem: "com.jarvis.brain", category: "watchdog")

// MARK: - CommChannel

enum CommChannel: String, Codable {
    case phone
    case sms
    case whatsapp
    case whatsapp_business
}

// MARK: - CommEventState

enum CommEventState: String, Codable {
    case missed
    case unread
    case received
    case replied
    case calledBack
    case dismissed
}

// MARK: - CommEvent

struct CommEvent {
    let eventId: String
    let channel: CommChannel
    let direction: String        // "incoming" | "outgoing"
    var state: CommEventState
    let contactName: String      // may be "Unknown"
    let contactHandle: String    // masked: last 4 digits only for phone numbers
    let receivedAt: Date
    let snippet: String?         // only if snippet retention enabled
    let sourceApp: String        // package name
    var lastPromptedAt: Date?
    var promptCount: Int
    let expiresAt: Date          // default: receivedAt + 4h
}

// MARK: - CommunicationWatchdogStore

/// Tracks unresolved communication events for proactive prompting.
/// Events are deduplicated by contactHandle + channel + receivedAt window (5 min).
final class CommunicationWatchdogStore {
    static let shared = CommunicationWatchdogStore()
    private init() {}

    private var events: [String: CommEvent] = [:]
    private let lock = NSLock()

    // MARK: - Settings

    var missedCallDelay: TimeInterval  = 600   // 10 min
    var smsDelay: TimeInterval         = 900   // 15 min
    var whatsappDelay: TimeInterval    = 1200  // 20 min
    var promptCooldown: TimeInterval   = 1800  // 30 min between re-prompts
    var maxPromptsPerEvent: Int        = 3
    var snippetRetentionSeconds: TimeInterval = 3600  // 1h (0 = disabled)

    // MARK: - Ingest

    func ingest(_ event: CommEvent) {
        lock.withLock {
            // Deduplication: same contactHandle + channel within a 5-minute window
            let isDuplicate = events.values.contains { existing in
                existing.contactHandle == event.contactHandle &&
                existing.channel == event.channel &&
                abs(existing.receivedAt.timeIntervalSince(event.receivedAt)) < 300
            }

            if isDuplicate {
                watchdogLogger.debug("watchdog: duplicate event suppressed channel=\(event.channel.rawValue)")
                return
            }

            events[event.eventId] = event
            watchdogLogger.info("watchdog: ingested eventId=\(event.eventId) channel=\(event.channel.rawValue) state=\(event.state.rawValue)")
        }
    }

    // MARK: - Resolve

    func resolve(eventId: String, state: CommEventState) {
        lock.withLock {
            guard events[eventId] != nil else { return }
            events[eventId]!.state = state
            watchdogLogger.info("watchdog: resolved eventId=\(eventId) state=\(state.rawValue)")
        }
    }

    // MARK: - Events ready to prompt

    /// Returns events that are past their delay threshold and either not yet prompted
    /// or have passed the cooldown window.
    func eventsReadyToPrompt() -> [CommEvent] {
        lock.withLock {
            let now = Date()
            return events.values.filter { event in
                // Must be unresolved
                guard event.state == .missed || event.state == .unread || event.state == .received else {
                    return false
                }
                // Must not be expired
                guard event.expiresAt > now else { return false }

                // Must not exceed max prompt count
                guard event.promptCount < maxPromptsPerEvent else { return false }

                // Must have passed the per-channel delay
                let delay = self.delay(for: event.channel)
                guard now.timeIntervalSince(event.receivedAt) >= delay else { return false }

                // Must have passed the cooldown since last prompt (if any)
                if let lastPrompted = event.lastPromptedAt {
                    return now.timeIntervalSince(lastPrompted) >= self.promptCooldown
                }

                return true
            }.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    // MARK: - Mark prompted

    func markPrompted(eventId: String) {
        lock.withLock {
            guard events[eventId] != nil else { return }
            events[eventId]!.lastPromptedAt = Date()
            events[eventId]!.promptCount   += 1
            watchdogLogger.debug("watchdog: markPrompted eventId=\(eventId) count=\(self.events[eventId]!.promptCount)")
        }
    }

    // MARK: - Eviction

    func evictExpired() {
        lock.withLock {
            let now = Date()
            let before = events.count
            events = events.filter { $0.value.expiresAt > now }
            // Also remove terminal states
            events = events.filter { e in
                switch e.value.state {
                case .replied, .calledBack, .dismissed: return false
                default: return true
                }
            }
            let evicted = before - events.count
            if evicted > 0 {
                watchdogLogger.debug("watchdog: evicted \(evicted) expired/resolved events")
            }
        }
    }

    func allActiveEvents() -> [CommEvent] {
        lock.withLock {
            events.values.filter {
                $0.state == .missed || $0.state == .unread || $0.state == .received
            }.sorted { $0.receivedAt > $1.receivedAt }
        }
    }

    // MARK: - Diagnostics

    var unresolvedCount: Int {
        lock.withLock {
            events.values.filter {
                $0.state == .missed || $0.state == .unread || $0.state == .received
            }.count
        }
    }

    var diagnosticsSummary: String {
        lock.withLock {
            let total      = events.count
            let unresolved = events.values.filter {
                $0.state == .missed || $0.state == .unread || $0.state == .received
            }.count
            return "total=\(total) unresolved=\(unresolved)"
        }
    }

    // MARK: - Private helpers

    private func delay(for channel: CommChannel) -> TimeInterval {
        switch channel {
        case .phone:             return missedCallDelay
        case .sms:               return smsDelay
        case .whatsapp:          return whatsappDelay
        case .whatsapp_business: return whatsappDelay
        }
    }
}
