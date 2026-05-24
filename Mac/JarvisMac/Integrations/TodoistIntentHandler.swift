import Foundation

/// Handles Todoist-domain intents previously inline in JarvisController.execute().
/// Extracted following the per-domain handler pattern — Sprint P decomposition.
@MainActor final class TodoistIntentHandler {

    private let prefs: PreferencesStore
    private let renderer: ResponseRenderer
    private let storedClient: () -> TodoistAPIClient?

    var speak: (String) -> Void = { _ in }
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    var currentTranscript: () -> String = { "" }

    init(
        prefs: PreferencesStore,
        renderer: ResponseRenderer,
        storedClient: @escaping () -> TodoistAPIClient?
    ) {
        self.prefs = prefs
        self.renderer = renderer
        self.storedClient = storedClient
    }

    /// Returns true if the intent was handled, false if it is not a Todoist intent.
    func handle(_ intent: Intent) async -> Bool {
        switch intent {
        case .showTasks, .whatAreMyTasks:
            guard let token = prefs.todoistAPIToken, !token.isEmpty else {
                speak(renderer.render(ResponseKey.todoistNotConfigured)); return true
            }
            let client = storedClient() ?? TodoistAPIClient(token: token)
            do {
                let tasks = try await client.getTasks()
                if tasks.isEmpty {
                    speak(renderer.render(ResponseKey.todoistNoTasks))
                } else {
                    let summary = client.spokenSummary(tasks: tasks)
                    speak(renderer.render(ResponseKey.todoistTasks,
                                          ["count": "\(tasks.count)",
                                           "count_label": tasks.count == 1 ? "task" : "tasks",
                                           "summary": summary]))
                }
            } catch {
                speak(renderer.render(ResponseKey.todoistTaskAddFailed))
            }
            return true

        case .overdueTasks:
            guard let token = prefs.todoistAPIToken, !token.isEmpty else {
                speak(renderer.render(ResponseKey.todoistNotConfigured)); return true
            }
            let client = storedClient() ?? TodoistAPIClient(token: token)
            do {
                let overdue = try await client.getOverdueTasks()
                if overdue.isEmpty {
                    speak(renderer.render(ResponseKey.todoistOverdueNone))
                } else {
                    let summary = client.spokenSummary(tasks: overdue)
                    speak(renderer.render(ResponseKey.todoistOverdue,
                                          ["count": "\(overdue.count)",
                                           "count_label": overdue.count == 1 ? "task" : "tasks",
                                           "summary": summary]))
                }
            } catch {
                speak(renderer.render(ResponseKey.todoistNotConfigured))
            }
            return true

        case .addTask(let text):
            guard let token = prefs.todoistAPIToken, !token.isEmpty else {
                speak(renderer.render(ResponseKey.todoistNotConfigured)); return true
            }
            let client = storedClient() ?? TodoistAPIClient(token: token)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let question = "What task should I add?"
                speak(question)
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: question,
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                try await client.createTask(content: text)
                speak(renderer.render(ResponseKey.todoistTaskAdded, ["text": text]))
            } catch {
                speak(renderer.render(ResponseKey.todoistTaskAddFailed))
            }
            return true

        case .completeTask(let text):
            guard let token = prefs.todoistAPIToken, !token.isEmpty else {
                speak(renderer.render(ResponseKey.todoistNotConfigured)); return true
            }
            let client = storedClient() ?? TodoistAPIClient(token: token)
            do {
                let found = try await client.closeTask(matching: text)
                speak(renderer.render(found ? ResponseKey.todoistTaskCompleted
                                            : ResponseKey.todoistTaskCompleteFailed))
            } catch {
                speak(renderer.render(ResponseKey.todoistTaskCompleteFailed))
            }
            return true

        default:
            return false
        }
    }
}
