import Foundation
import os

// MARK: - EscalationStage

enum EscalationStage: Int, Codable, Comparable {
    case preWarning  = 1   // 10 minutes before
    case warning     = 2   // 5 minutes before
    case imminent    = 3   // 2 minutes before

    static func < (lhs: EscalationStage, rhs: EscalationStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var minutesBefore: Int {
        switch self {
        case .preWarning: return 10
        case .warning:    return 5
        case .imminent:   return 2
        }
    }

    var spokenPrefix: String {
        switch self {
        case .preWarning: return "In 10 minutes,"
        case .warning:    return "5-minute warning —"
        case .imminent:   return "Almost time —"
        }
    }

    var priority: SignalPriority {
        switch self {
        case .preWarning: return .normal
        case .warning:    return .high
        case .imminent:   return .urgent
        }
    }
}

// MARK: - TrackedReminder

struct TrackedReminder: Identifiable, Codable {
    let id: String
    var title: String
    var dueDate: Date
    var source: String          // "calendar", "todoist", "voice"
    var deliveredStages: [EscalationStage]
    var isSnoozed: Bool
    var snoozeUntil: Date?

    var isExpired: Bool { dueDate < Date().addingTimeInterval(-300) }

    var nextStage: EscalationStage? {
        let remaining = EscalationStage.allCases.filter { !deliveredStages.contains($0) }
        return remaining.first
    }
}

// MARK: - ReminderEscalationModel

/// Three-stage reminder escalation: 10-min pre-warning → 5-min warning → 2-min imminent.
///
/// Designed to work alongside `CalendarProactivityProvider` (which handles its own
/// 10-min/1-min signals). This model adds **persistence** (survives app restart) and
/// **multi-stage escalation** with user snooze support.
///
/// Signals are published via `ProactivityOrchestrator.shared.providerPublish`.
@MainActor
final class ReminderEscalationModel {

    static let shared = ReminderEscalationModel()

    private let log = Logger(subsystem: "com.jarvis", category: "intelligence.escalation")
    private var pollTask: Task<Void, Never>?
    private(set) var trackedReminders: [TrackedReminder] = []

    // MARK: - Lifecycle

    func start() {
        loadFromDisk()
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { checkEscalations() }
            }
        }
    }

    // MARK: - Registration

    func track(title: String, dueDate: Date, source: String) {
        let id = "\(source)-\(title.lowercased().filter { $0.isLetter || $0.isNumber })"
        guard !trackedReminders.contains(where: { $0.id == id }) else { return }
        let reminder = TrackedReminder(id: id, title: title, dueDate: dueDate, source: source,
                                       deliveredStages: [], isSnoozed: false)
        trackedReminders.append(reminder)
        saveToDisk()
    }

    func snooze(_ id: String, minutes: Int = 5) {
        if let idx = trackedReminders.firstIndex(where: { $0.id == id }) {
            trackedReminders[idx].isSnoozed = true
            trackedReminders[idx].snoozeUntil = Date().addingTimeInterval(Double(minutes) * 60)
            saveToDisk()
        }
    }

    func dismiss(_ id: String) {
        trackedReminders.removeAll { $0.id == id }
        saveToDisk()
    }

    // MARK: - Escalation check

    func checkEscalations() {
        let now = Date()
        // Remove expired reminders (> 5 min past due)
        trackedReminders.removeAll { $0.isExpired }

        for i in trackedReminders.indices {
            var reminder = trackedReminders[i]
            guard !reminder.isExpired else { continue }
            if reminder.isSnoozed {
                if let until = reminder.snoozeUntil, now > until {
                    trackedReminders[i].isSnoozed = false
                    trackedReminders[i].snoozeUntil = nil
                } else { continue }
            }
            guard let stage = reminder.nextStage else { continue }

            let minutesUntilDue = reminder.dueDate.timeIntervalSince(now) / 60
            if minutesUntilDue <= Double(stage.minutesBefore) {
                deliver(reminder: reminder, stage: stage)
                trackedReminders[i].deliveredStages.append(stage)
            }
        }
        saveToDisk()
    }

    private func deliver(reminder: TrackedReminder, stage: EscalationStage) {
        let spoken = "\(stage.spokenPrefix) \(reminder.title)."
        let signal = ProactivitySignal(
            source: .calendar,
            title: reminder.title,
            body: "Due in \(stage.minutesBefore) minutes",
            priority: stage.priority,
            dedupeKey: "reminder.\(reminder.id).\(stage.rawValue)",
            spokenText: spoken
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
        log.info("Escalated '\(reminder.title)' at stage \(stage.rawValue)")
    }

    // MARK: - Persistence

    private var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac")
            .appendingPathComponent("reminder_escalations.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([TrackedReminder].self, from: data)
        else { return }
        trackedReminders = loaded.filter { !$0.isExpired }
    }

    private func saveToDisk() {
        let reminders = trackedReminders
        Task.detached(priority: .utility) { [url = fileURL] in
            guard let data = try? JSONEncoder().encode(reminders) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    var diagnosticSummary: String {
        "tracked=\(trackedReminders.count) active=\(trackedReminders.filter { !$0.isSnoozed }.count)"
    }
}

// MARK: - EscalationStage.allCases

extension EscalationStage: CaseIterable {}
