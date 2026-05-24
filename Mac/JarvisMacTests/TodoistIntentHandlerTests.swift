import XCTest
@testable import JarvisMac

final class TodoistIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> TodoistIntentHandler {
        let prefs    = PreferencesStore()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return TodoistIntentHandler(prefs: prefs, renderer: renderer, storedClient: { nil })
    }

    // MARK: - Return value

    @MainActor
    func test_todoistIntents_returnTrue() async {
        let h = makeHandler()
        h.speak = { _ in }
        h.setPendingContext = { _ in }
        h.currentTranscript = { "" }

        let cases: [Intent] = [
            .showTasks,
            .whatAreMyTasks,
            .overdueTasks,
            .addTask(text: "Buy milk"),
            .completeTask(text: "Buy milk"),
        ]
        for intent in cases {
            let handled = await h.handle(intent)
            XCTAssertTrue(handled, "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonTodoistIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }

        let handled = await h.handle(.currentWeather)
        XCTAssertFalse(handled)
    }

    // MARK: - Not configured

    @MainActor
    func test_showTasks_withNoToken_speaksNotConfigured() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        // No token in keychain / prefs → should speak not-configured immediately
        _ = await h.handle(.showTasks)

        XCTAssertFalse(spokenTexts.isEmpty)
        XCTAssertFalse(spokenTexts.first?.isEmpty ?? true)
    }

    // MARK: - Follow-up for empty addTask

    @MainActor
    func test_addTask_withEmptyText_setsPendingContext() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        var pendingContextSet = false
        h.speak = { spokenTexts.append($0) }
        h.setPendingContext = { _ in pendingContextSet = true }
        h.currentTranscript = { "add a task" }

        // Inject a fake token so the guard passes
        // (We use a custom storedClient closure returning nil — token gate
        //  checks prefs.todoistAPIToken which reads Keychain. We can't write
        //  Keychain in tests, so verify the setPendingContext path is reachable
        //  only when token exists by creating a handler with a dummy client.)
        let prefs    = PreferencesStore()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())

        // Build a version that bypasses the token guard by providing a stored client
        var pendingContextSetB = false
        var spokenB = [String]()
        let hB = TodoistIntentHandler(
            prefs:         prefs,
            renderer:      renderer,
            storedClient:  { TodoistAPIClient(token: "fake-token") }
        )
        hB.speak             = { spokenB.append($0) }
        hB.setPendingContext = { _ in pendingContextSetB = true }
        hB.currentTranscript = { "add a task" }

        // With a real (but fake-token) client the token guard passes.
        // `.addTask("")` should ask a clarifying question and set context.
        // Note: this makes a network call in production; in tests the call
        // never fires because setPendingContext returns first.
        _ = await hB.handle(.addTask(text: ""))

        // The handler should have asked a question and set pending context
        // without making a real API call (the guard returns after setPendingContext).
        XCTAssertFalse(spokenB.isEmpty, "Expected clarifying question spoken")
        XCTAssertTrue(pendingContextSetB, "Expected pending context to be set")
    }
}
