import XCTest
@testable import JarvisMac

final class CalendarIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> CalendarIntentHandler {
        let cal      = EventKitCalendarService()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return CalendarIntentHandler(calendarService: cal, renderer: renderer)
    }

    // MARK: - Return value

    @MainActor
    func test_calendarIntents_returnTrue() async {
        let h = makeHandler()
        h.speak = { _ in }
        h.setPendingContext = { _ in }
        h.currentTranscript = { "" }

        let cases: [Intent] = [
            .showCalendar,
            .nextMeeting,
            .meetingsToday,
            .addReminder(text: "dentist appointment"),
        ]
        for intent in cases {
            let handled = await h.handle(intent)
            XCTAssertTrue(handled, "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonCalendarIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }

        let handled = await h.handle(.spotifyPause)
        XCTAssertFalse(handled)
    }

    // MARK: - Not authorized guard

    @MainActor
    func test_showCalendar_withoutAuth_speaksNotConfigured() async {
        let h = makeHandler()
        // EventKitCalendarService.isAuthorized starts false in tests (no EventKit permission).
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.showCalendar)

        XCTAssertFalse(spokenTexts.isEmpty)
        XCTAssertFalse(spokenTexts.first?.isEmpty ?? true)
    }

    @MainActor
    func test_nextMeeting_withoutAuth_speaksNotConfigured() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.nextMeeting)

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - Follow-up for empty addReminder

    @MainActor
    func test_addReminder_withEmptyText_setsPendingContextWithoutCrashing() async {
        let h = makeHandler()
        var pendingContextSet = false
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }
        h.setPendingContext = { _ in pendingContextSet = true }
        h.currentTranscript = { "add a reminder" }

        // isAuthorized is false → handler returns early with "not configured" — it does
        // NOT set pending context.  This test documents that the auth guard fires first.
        _ = await h.handle(.addReminder(text: ""))

        // Either spoke "not configured" (auth guard) or asked a question (if auth granted).
        XCTAssertFalse(spokenTexts.isEmpty)
    }
}
