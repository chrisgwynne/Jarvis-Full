import Foundation

/// Internal notification queue. Collects events, defers delivery when user
/// is focused, drains when attention relaxes. No macOS UNUserNotification —
/// all internal to Jarvis (toast + optional TTS).
@Observable
@MainActor
final class NotificationQueue {

    private(set) var pending: [NotificationEvent] = []
    private(set) var recentlyDelivered: [NotificationEvent] = []
    private let maxPending = 20
    private let maxDelivered = 50

    /// Called by JarvisController to emit toast + optional TTS.
    var onDeliver: ((NotificationEvent) -> Void)?

    // MARK: - Enqueue

    func enqueue(_ event: NotificationEvent) {
        guard event.priority > .silent else {
            Log.app.debug("notification silent-dropped: \(event.title)")
            return
        }
        // Deduplicate: don't repeat same title within 30 seconds
        let recent = recentlyDelivered.filter { -$0.timestamp.timeIntervalSinceNow < 30 }
        if recent.contains(where: { $0.title == event.title }) { return }

        if event.priority == .critical {
            // Critical: deliver immediately, bypass queue
            deliver(event)
        } else {
            pending.append(event)
            if pending.count > maxPending {
                pending.removeFirst(pending.count - maxPending)
            }
        }
    }

    func enqueue(priority: NotificationPriority,
                 title: String,
                 body: String? = nil,
                 symbol: String = "bell.fill",
                 category: String = "general") {
        enqueue(NotificationEvent(priority: priority,
                                  title: title,
                                  body: body,
                                  symbol: symbol,
                                  category: category))
    }

    // MARK: - Drain

    /// Called when attention state becomes permissive (e.g. idle, passive).
    func drainIfAppropriate(attention: AttentionState) {
        guard !attention.suppressesNotifications else { return }
        guard !pending.isEmpty else { return }

        // Deliver up to 2 queued items per drain cycle (avoid flood)
        let batch = pending.prefix(2)
        pending.removeFirst(min(2, pending.count))
        for event in batch { deliver(event) }
    }

    // MARK: - Internal

    private func deliver(_ event: NotificationEvent) {
        var e = event
        e.delivered = true
        recentlyDelivered.append(e)
        if recentlyDelivered.count > maxDelivered {
            recentlyDelivered.removeFirst(recentlyDelivered.count - maxDelivered)
        }
        Log.app.debug("notification deliver [\(event.priority.displayName)]: \(event.title)")
        onDeliver?(e)
    }
}
