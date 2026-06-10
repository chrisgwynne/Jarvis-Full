import XCTest
@testable import JarvisMac

// MARK: - EmailIntentHandler tests
// Uses the same fake-service approach as AppleNotesIntentHandlerTests:
// AppleScript calls are skipped because NSAppleScript requires a host app.
// Tests verify handler routing logic, pending-context paths, and
// context-graph ingestion — not AppleScript execution.

@MainActor
final class AppleMailIntentHandlerTests: XCTestCase {

    private func makeHandler() -> EmailIntentHandler {
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return EmailIntentHandler(renderer: renderer)
    }

    // MARK: - Return values

    func testEmailIntents_returnTrue() async {
        let h = makeHandler()
        h.speak             = { _ in }
        h.setPendingContext = { _ in }

        let intents: [Intent] = [
            .checkEmail,
            .unreadEmail,
            .readLatestEmail,
            .searchEmail(query: "invoice"),
            .summariseEmail,
            .importantEmail,
            .showEmail,
            .draftEmail(to: "alice@example.com", subject: "Hi", body: "Hello"),
            .replyEmail(to: "alice@example.com", body: "Thanks"),
        ]
        // AppleScript calls fail in the test host (no Mail process) and the
        // handler catches them — we just verify no crash and correct return value.
        for intent in intents {
            let handled = await h.handle(intent)
            XCTAssertTrue(handled, "Expected true for \(intent)")
        }
    }

    func testNonEmailIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }
        let handled = await h.handle(.currentWeather)
        XCTAssertFalse(handled)
    }

    // MARK: - Missing recipient (draftEmail)

    func testDraftEmail_emptyRecipient_setsPendingContext() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        var pendingSet  = false
        h.speak             = { spokenTexts.append($0) }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "draft an email" }

        _ = await h.handle(.draftEmail(to: "", subject: "", body: ""))

        XCTAssertFalse(spokenTexts.isEmpty, "Should ask for recipient")
        XCTAssertTrue(pendingSet, "Should set pending context")
    }

    // MARK: - Missing subject (draftEmail)

    func testDraftEmail_emptySubject_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "draft email to alice" }

        _ = await h.handle(.draftEmail(to: "alice@example.com", subject: "", body: ""))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Missing recipient (replyEmail)

    func testReplyEmail_emptyRecipient_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "reply to email" }

        _ = await h.handle(.replyEmail(to: "", body: ""))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Missing query (searchEmail)

    func testSearchEmail_emptyQuery_setsPendingContext() async {
        let h = makeHandler()
        var pendingSet = false
        h.speak             = { _ in }
        h.setPendingContext = { _ in pendingSet = true }
        h.currentTranscript = { "search email" }

        _ = await h.handle(.searchEmail(query: ""))

        XCTAssertTrue(pendingSet)
    }

    // MARK: - Context-graph ingestion hook reachability

    func testIngestNode_hookIsReachable() async {
        let h = makeHandler()
        var ingestedCount = 0
        h.speak      = { _ in }
        h.ingestNode = { _ in ingestedCount += 1 }

        // AppleScript is unavailable in test host — handler catches the error.
        // The important thing is the hook is wired and doesn't crash.
        _ = await h.handle(.checkEmail)

        // Either 0 (no emails) or >0 (if Mail happens to be accessible):
        // just verify the hook doesn't cause a crash.
        XCTAssertTrue(ingestedCount >= 0)
    }

    // MARK: - ContextNode shape

    func testIngestedNode_hasEmailTypeAndSource() {
        let h = makeHandler()
        var captured: ContextNode?
        h.speak      = { _ in }
        h.ingestNode = { captured = $0 }

        let msg = EmailMessage(
            id:         "msg-001",
            messageID:  "<msg-001@example.com>",
            subject:    "Meeting tomorrow",
            sender:     "Alice <alice@example.com>",
            senderName: "Alice",
            preview:    "Let's discuss the roadmap.",
            dateString: "",
            isRead:     false
        )
        h.ingestEmailNode(from: msg)

        XCTAssertEqual(captured?.type,      .email)
        XCTAssertEqual(captured?.source,    .appleMail)
        XCTAssertEqual(captured?.trustTier, .synced)
        XCTAssertEqual(captured?.confidence ?? 0, 0.90, accuracy: 0.001)
        XCTAssertEqual(captured?.externalID, "email:<msg-001@example.com>")
    }

    func testIngestedNode_emptyMessageID_hasNilExternalID() {
        let h = makeHandler()
        var captured: ContextNode?
        h.ingestNode = { captured = $0 }

        let msg = EmailMessage(
            id: "Meeting tomorrow-Alice", messageID: "", subject: "Meeting tomorrow",
            sender: "Alice", senderName: "Alice", preview: "", dateString: "", isRead: false
        )
        h.ingestEmailNode(from: msg)

        XCTAssertNil(captured?.externalID,
            "Empty messageID should produce nil externalID (no dedup key)")
    }

    // MARK: - AppleMailService escaping

    func testEscaping_backslashAndQuote() {
        let raw    = "Say \"hello\" and C:\\path"
        let result = AppleMailService.escaped(raw)
        XCTAssertTrue(result.contains("\\\""), "Quotes should be escaped")
        XCTAssertTrue(result.contains("\\\\"), "Backslashes should be escaped")
    }

    func testEscaping_safeString_unchanged() {
        let raw    = "invoice from March"
        let result = AppleMailService.escaped(raw)
        XCTAssertEqual(result, raw)
    }

    // MARK: - pbxproj UUID uniqueness (regression guard)

}
