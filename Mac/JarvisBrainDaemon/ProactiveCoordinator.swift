import Foundation
import OSLog

private let proactiveLogger = Logger(subsystem: "com.jarvis.brain", category: "proactive")

// MARK: - ProactiveCoordinator

/// Decides when and where to emit proactive prompts to connected devices.
/// Called periodically (every 60 s) by BrainDaemonServer and on new comm events.
final class ProactiveCoordinator {
    static let shared = ProactiveCoordinator()
    private init() {}

    // MARK: - Settings

    /// Local-time hour at which quiet hours begin (inclusive). Default: 22:00.
    var quietHoursStart: Int = 22
    /// Local-time hour at which quiet hours end (exclusive). Default: 08:00.
    var quietHoursEnd: Int   = 8

    // MARK: - Tick

    /// Called periodically (every 60 s) and optionally on new comm events.
    func tick(router: DaemonMessageRouter) {
        let readyEvents = CommunicationWatchdogStore.shared.eventsReadyToPrompt()
        guard !readyEvents.isEmpty else { return }

        // Suppress during quiet hours
        if isQuietHours() {
            proactiveLogger.debug("proactive: quiet hours — skipping \(readyEvents.count) events")
            return
        }

        // Suppress when any device is driving or sleeping
        if shouldSuppressForPresence() {
            proactiveLogger.debug("proactive: presence suppression — skipping \(readyEvents.count) events")
            return
        }

        for event in readyEvents {
            let prompt = buildCommPrompt(event: event)
            let envelope = DaemonMessageEnvelope.make(
                type: "proactive.comm.prompt",
                target: .macApp,
                payload: prompt,
                sourcePlatform: "daemon"
            )
            router.routeToMacOrQueuePublic(envelope)
            CommunicationWatchdogStore.shared.markPrompted(eventId: event.eventId)
            proactiveLogger.info("proactive: emitted comm.prompt eventId=\(event.eventId) channel=\(event.channel.rawValue)")
        }

        // Update last comm prompt context
        if let first = readyEvents.first {
            ContextStore.shared.set(
                key: ContextStore.lastCommPrompt,
                value: buildCommPrompt(event: first),
                sourceDeviceId: "daemon",
                ttlSeconds: 3600
            )
        }
    }

    // MARK: - Private

    private func isQuietHours() -> Bool {
        let cal  = Calendar.current
        let hour = cal.component(.hour, from: Date())
        if quietHoursStart > quietHoursEnd {
            // Spans midnight: quiet if hour >= start OR hour < end
            return hour >= quietHoursStart || hour < quietHoursEnd
        } else {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
    }

    private func shouldSuppressForPresence() -> Bool {
        PresenceStore.shared.anyDeviceDriving ||
        PresenceStore.shared.allPresence.contains { $0.focusMode == "sleep" }
    }

    private func buildCommPrompt(event: CommEvent) -> JSONValue {
        var fields: [String: JSONValue] = [
            "eventId":     .string(event.eventId),
            "channel":     .string(event.channel.rawValue),
            "direction":   .string(event.direction),
            "state":       .string(event.state.rawValue),
            "contactName": .string(event.contactName),
            "promptCount": .int(event.promptCount),
            "receivedAt":  .string(ISO8601DateFormatter().string(from: event.receivedAt))
        ]
        // Intentionally omit contactHandle (phone/handle — private) and snippet from logs;
        // still pass them in the payload for the Mac brain to reason on, but flag privately.
        // The Mac brain must not log these fields.
        fields["contactHandle"] = .string(event.contactHandle)
        if let snippet = event.snippet {
            fields["snippet"] = .string(snippet)
        }
        return .object(fields)
    }
}

// MARK: - DaemonMessageRouter public bridge

/// Exposes `routeToMacOrQueue` to ProactiveCoordinator without breaking router encapsulation.
extension DaemonMessageRouter {
    /// Routes an envelope to the Mac app, queuing it if Mac is offline.
    /// This variant is safe to call from outside the router's internal queue.
    func routeToMacOrQueuePublic(_ envelope: DaemonMessageEnvelope) {
        // Use deliverToMac which already handles Mac-offline queueing
        _ = deliverToMac(envelope)
    }
}
