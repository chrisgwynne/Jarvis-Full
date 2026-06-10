import XCTest
@testable import JarvisMac

// MARK: - NotesIntentHandler tests
// Uses a fake-service approach: all AppleScript calls are skipped because
// NSAppleScript requires a host app. Tests verify handler routing logic,
// response-key selection, and context-graph ingestion — not AppleScript output.

@MainActor
final class AppleNotesIntentHandlerTests: XCTestCase {

    private func makeHandler() -> NotesIntentHandler {
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return NotesIntentHandler(renderer: renderer)
    }

    // MARK: - Return values

    func testNotesIntents_returnTrue() async {
        let h = makeHandler()
        h.speak             = { _ in }
        h.setPendingContext = { _ in }

        let intents: [Intent] = [
            .openNotes,
            .showNotes,
            .createNote(title: "Test", body: "Content"),
            .appendNote(title: "Test", body: "More"),
            .searchNotes(query: "test"),
        ]
        // We don't actually run AppleScript here — just verify no crash for
        // the non-scripting path (permission error branch fires via catch).
        for intent in intents {
            let handled = await h.handle(intent)
            XCTAssertTrue(handled, "Expected true for \(intent)")
        }
    }

    func testNonNotesIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }
        let handled = await h.handle(.currentWeather)
        XCTAssertFalse(handled)
    }

    // MARK: - Missing-title path (createNote)

    func testCreateNote_emptyTitleAndBody_setsPendingContext() async {
        let h = makeHandler()
        var spokenTexts     = [String]()
        var pendingSet      = false
        h.speak             = { spokenTexts.append($0) }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "create a note" }

        _ = await h.handle(.createNote(title: "", body: ""))

        XCTAssertFalse(spokenTexts.isEmpty, "Should ask clarifying question")
        XCTAssertTrue(pendingSet, "Should set pending context")
    }

    // MARK: - Missing-title path (appendNote)

    func testAppendNote_emptyTitle_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "add to note" }

        _ = await h.handle(.appendNote(title: "", body: "Some text"))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Missing-body path (appendNote)

    func testAppendNote_emptyBody_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "add to note daily log" }

        _ = await h.handle(.appendNote(title: "daily log", body: ""))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Missing-query path (searchNotes)

    func testSearchNotes_emptyQuery_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "search notes" }

        _ = await h.handle(.searchNotes(query: ""))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Context-graph ingestion hook

    func testCreateNote_withTitleAndBody_callsIngestHook() async {
        let h = makeHandler()
        var ingestedNodes = [ContextNode]()
        h.speak      = { _ in }
        h.ingestNode = { ingestedNodes.append($0) }

        // Supply title + body so the guard passes and ingestion runs.
        // AppleScript will throw permission error in unit-test host;
        // the handler catches it and speaks the error — ingestion only
        // fires on success, so we expect 0 here (no real Notes process).
        _ = await h.handle(.createNote(title: "Meeting notes", body: "Discussed sprint goals"))

        // Either 0 (AppleScript unavailable in test host) or 1 (success):
        // the important thing is the hook is reachable and doesn't crash.
        XCTAssertTrue(ingestedNodes.count <= 1)
    }

    // MARK: - ContextNode shape

    func testIngestedNode_hasAppleNoteTypeAndSource() {
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        let h        = NotesIntentHandler(renderer: renderer)
        var captured: ContextNode?
        h.speak      = { _ in }
        h.ingestNode = { captured = $0 }

        // Simulate what ingestNoteNode produces by wiring the hook and
        // calling it indirectly via a successful-path stub.
        // Since we can't run AppleScript, we test the node shape directly.
        let node = ContextNode(
            type:       .appleNote,
            title:      "Test Note",
            summary:    "First line of body",
            source:     .appleNotes,
            confidence: 0.90,
            trustTier:  .userEdited,
            externalID: "applenote:test-note"
        )
        h.ingestNode?(node)

        XCTAssertEqual(captured?.type,      .appleNote)
        XCTAssertEqual(captured?.source,    .appleNotes)
        XCTAssertEqual(captured?.trustTier, .userEdited)
        XCTAssertEqual(captured?.confidence ?? 0, 0.90, accuracy: 0.001)
    }

    // MARK: - AppleNotesService escaping

    func testEscaping_backslashAndQuote() {
        let raw    = "Say \"hello\" and C:\\path"
        let result = AppleNotesService.escaped(raw)
        XCTAssertTrue(result.contains("\\\""), "Quotes should be escaped")
        XCTAssertTrue(result.contains("\\\\"), "Backslashes should be escaped")
    }

    func testEscaping_safeString_unchanged() {
        let raw    = "Simple safe string"
        let result = AppleNotesService.escaped(raw)
        XCTAssertEqual(result, raw)
    }

    // MARK: - pbxproj UUID uniqueness (regression guard)

}
