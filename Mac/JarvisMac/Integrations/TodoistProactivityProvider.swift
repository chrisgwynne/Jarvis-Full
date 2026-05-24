import Foundation

/// Polls Todoist and emits ProactivitySignals for overdue tasks.
///
/// - Announces overdue tasks once per day during the morning window (08:30–09:30).
/// - Polls every 5 minutes, but only speaks during the morning window.
@MainActor
final class TodoistProactivityProvider: ProactivitySignalProvider {
    let source: SignalSource = .todoist

    private weak var todoistClient: TodoistAPIClient?
    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private weak var prefs: PreferencesStore?
    private var pollTask: Task<Void, Never>?

    init(todoistClient: TodoistAPIClient,
         engine: ProactivityEngine,
         appState: AppState,
         prefs: PreferencesStore) {
        self.todoistClient = todoistClient
        self.engine = engine
        self.appState = appState
        self.prefs = prefs
    }

    /// True when an alert was already fired today (calendar-day comparison).
    private func firedToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDate(date, inSameDayAs: Date())
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollNow()
                try? await Task.sleep(for: .seconds(300)) // every 5 min
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard let client = todoistClient else { return }

        let today = Calendar.current.startOfDay(for: Date())

        // Only announce overdue tasks during morning window (08:30–09:30)
        let comps  = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour   = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let isMorningWindow = (hour == 8 && minute >= 30) || hour == 9

        // The persisted timestamp gates duplicate alerts across launches —
        // restarting at 08:45 used to re-fire the overdue announcement.
        guard isMorningWindow, !firedToday(prefs?.current.lastTodoistOverdueDate) else { return }

        guard let tasks = try? await client.getTasks() else { return }

        let overdue = tasks.filter(\.isOverdue)
        guard !overdue.isEmpty else { return }

        prefs?.update { $0.lastTodoistOverdueDate = Date() }
        let count    = overdue.count
        let firstTwo = overdue.prefix(2).map(\.content).joined(separator: ", ")
        let spoken   = count == 1
            ? "You have 1 overdue task: \(overdue[0].content)."
            : "You have \(count) overdue tasks including \(firstTwo)."
        let signal = ProactivitySignal(
            source: .todoist,
            title: "\(count) overdue task\(count == 1 ? "" : "s")",
            body: firstTwo,
            category: "overdue",
            priority: .high,
            dedupeKey: "todoist.overdue.\(today.timeIntervalSince1970)",
            spokenText: spoken,
            requiresAttention: false
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
    }
}
