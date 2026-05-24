import Foundation
import EventKit

/// Polls the user's calendar and emits ProactivitySignals for:
/// - Meetings starting in ~10 minutes (high priority)
/// - Meetings starting in ~1 minute (urgent)
///
/// Polls every 60 seconds. Uses EventKitCalendarService which is already
/// authorized by JarvisController at startup.
@MainActor
final class CalendarProactivityProvider: ProactivitySignalProvider {
    let source: SignalSource = .calendar

    private weak var calendarService: EventKitCalendarService?
    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private var pollTask: Task<Void, Never>?

    // Track which events we've already announced at each warning tier
    private var announced10min: Set<String> = []
    private var announced1min:  Set<String> = []
    private var lastCleanup = Date()

    init(calendarService: EventKitCalendarService,
         engine: ProactivityEngine,
         appState: AppState) {
        self.calendarService = calendarService
        self.engine = engine
        self.appState = appState
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollNow()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard let calendar = calendarService, calendar.isAuthorized else { return }

        let now = Date()
        let lookahead = Calendar.current.date(byAdding: .minute, value: 15, to: now)!
        let upcoming = calendar.events(from: now, to: lookahead)

        for event in upcoming {
            let minutesUntil = Int(event.startDate.timeIntervalSince(now) / 60)
            // Stable ID even when eventIdentifier and title are both nil — UUID()
            // would mint a new value every poll, breaking dedup and double-firing
            // every 10-min / 1-min alert.
            let eventId = event.eventIdentifier
                ?? "untitled-\(Int(event.startDate.timeIntervalSince1970))"
            let title = event.title ?? "a meeting"

            // Feed escalation model so it can deliver staged reminders
            // (10-min normal, 5-min high, 2-min urgent) independently.
            ReminderEscalationModel.shared.track(
                title: title, dueDate: event.startDate, source: "calendar"
            )

            // 10-minute warning (between 8–12 minutes away)
            if minutesUntil >= 8 && minutesUntil <= 12 && !announced10min.contains(eventId) {
                announced10min.insert(eventId)
                let location = event.location.map { " at \($0)" } ?? ""
                let signal = ProactivitySignal(
                    source: .calendar,
                    title: "Meeting in 10 min: \(title)",
                    body: location.isEmpty ? "Starting soon" : String(location.dropFirst()),
                    category: "meeting_warning",
                    priority: .high,
                    dedupeKey: "calendar.10min.\(eventId)",
                    spokenText: "Heads up — '\(title)' starts in about 10 minutes.",
                    requiresAttention: true
                )
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }

            // 1-minute warning (between 0–2 minutes away)
            if minutesUntil >= 0 && minutesUntil <= 2 && !announced1min.contains(eventId) {
                announced1min.insert(eventId)
                let signal = ProactivitySignal(
                    source: .calendar,
                    title: "Starting now: \(title)",
                    body: "Your meeting is starting",
                    category: "meeting_starting",
                    priority: .urgent,
                    dedupeKey: "calendar.1min.\(eventId)",
                    spokenText: "'\(title)' is starting now.",
                    requiresAttention: true
                )
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }
        }

        cleanupIfNeeded()
    }

    private func cleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCleanup) > 86400 else { return }
        announced10min.removeAll()
        announced1min.removeAll()
        lastCleanup = Date()
    }
}
