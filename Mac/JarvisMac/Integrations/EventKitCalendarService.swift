import Foundation
import EventKit

/// Local calendar access via EventKit — uses macOS Calendar.app which syncs
/// Google Calendar, iCloud, Exchange, and any other accounts the user has
/// configured. No OAuth, no cloud calls, no API tokens needed.
@MainActor
final class EventKitCalendarService {

    private let store = EKEventStore()
    private(set) var isAuthorized = false
    private(set) var lastError: String?

    // MARK: - Permission

    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                isAuthorized = granted
                return granted
            } catch {
                lastError = error.localizedDescription
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { [weak self] granted, err in
                    Task { @MainActor in
                        self?.isAuthorized = granted
                        if let err { self?.lastError = err.localizedDescription }
                        cont.resume(returning: granted)
                    }
                }
            }
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Queries

    /// All events for today (midnight → 23:59:59).
    func eventsToday() -> [EKEvent] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return events(from: start, to: end)
    }

    /// The single next upcoming event from now.
    func nextEvent() -> EKEvent? {
        guard isAuthorized else { return nil }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return events(from: now, to: end).first
    }

    /// Events in a window, sorted by start date.
    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard isAuthorized else { return [] }
        let calendars = store.calendars(for: .event)
        let pred = store.predicateForEvents(withStart: start, end: end,
                                            calendars: calendars)
        return store.events(matching: pred)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Reminders

    /// Create an EKReminder in the default reminders list.
    func addReminder(text: String) async -> Bool {
        guard isAuthorized else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()
        let dueComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date().addingTimeInterval(3600)   // default: 1 hour from now
        )
        reminder.dueDateComponents = dueComponents
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Formatting helpers

    func spokenSummaryToday() -> (count: Int, summary: String) {
        let events = eventsToday()
        if events.isEmpty { return (0, "") }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        let names = events.prefix(3).map { "\($0.title ?? "event") at \(fmt.string(from: $0.startDate))" }
        let summary = names.joined(separator: ", ")
        return (events.count, summary)
    }

    func spokenNextMeeting() -> String? {
        guard let next = nextEvent() else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let timeStr = fmt.string(from: next.startDate)
        return "\(next.title ?? "a meeting") at \(timeStr)"
    }
}
