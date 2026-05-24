import XCTest
@testable import JarvisMac

final class RedditIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeRouter() -> LLMRouter {
        LLMRouter(
            xai: XAIProvider(
                baseURL:   { "" },
                modelName: { "" },
                enabled:   { false },
                apiKey:    { nil }
            ),
            miniMax: MiniMaxProvider(
                baseURL:   { "" },
                modelName: { "" },
                enabled:   { false },
                apiKey:    { nil }
            ),
            gemini: GeminiProvider(
                baseURL:     { "" },
                modelName:   { "" },
                visionModel: { "" },
                enabled:     { false },
                apiKey:      { nil }
            ),
            local: LlamaCppProvider(
                baseURL:   { "" },
                modelName: { "" },
                enabled:   { false }
            )
        )
    }

    @MainActor
    private func makeHandler() -> RedditIntentHandler {
        let router = makeRouter()
        router.mode = .disabled // disable actual LLM calls in tests
        return RedditIntentHandler(
            redditStore: RedditStore(),
            state:       AppState(),
            llmRouter:   router
        )
    }

    // MARK: - Return value

    @MainActor
    func test_redditIntents_returnTrue() {
        let h = makeHandler()
        h.speak       = { _ in }
        h.openOverlay = { _ in }

        let intents: [Intent] = [
            .showReddit,
            .showRedditTop,
            .showSubreddit(name: "swift"),
            .redditOpenIndex(index: 0),
            .redditOpenInBrowser,
            .redditSavePost,
            .redditRefresh,
        ]
        for intent in intents {
            XCTAssertTrue(h.handle(intent), "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_asyncRedditIntents_returnTrue() {
        let h = makeHandler()
        h.speak       = { _ in }
        h.openOverlay = { _ in }

        // These fire Tasks but handle() returns true synchronously
        for intent: Intent in [.redditQuery(query: "swift"), .redditShowComments,
                                .redditSummarisePost, .redditSummariseComments] {
            XCTAssertTrue(h.handle(intent), "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonRedditIntent_returnsFalse() {
        let h = makeHandler()
        h.speak       = { _ in }
        h.openOverlay = { _ in }

        XCTAssertFalse(h.handle(.showCalendar))
        XCTAssertFalse(h.handle(.spotifyPause))
    }

    // MARK: - showReddit

    @MainActor
    func test_showReddit_opensOverlayAndSpeaks() {
        let h = makeHandler()
        var openedOverlays = [OverlayKind]()
        var spokenTexts    = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { openedOverlays.append($0) }

        _ = h.handle(.showReddit)

        XCTAssertTrue(openedOverlays.contains(.reddit))
        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - showSubreddit not configured

    @MainActor
    func test_showSubreddit_withUnknownName_setsErrorAndSpeaks() {
        let router = makeRouter()
        router.mode = .disabled
        let state = AppState()
        let h = RedditIntentHandler(
            redditStore: RedditStore(),
            state:       state,
            llmRouter:   router
        )
        var spokenTexts    = [String]()
        var openedOverlays = [OverlayKind]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { openedOverlays.append($0) }

        _ = h.handle(.showSubreddit(name: "nonexistent_subreddit_xyz"))

        XCTAssertFalse(spokenTexts.isEmpty)
        XCTAssertNotNil(state.redditLastError)
    }

    // MARK: - redditRefresh

    @MainActor
    func test_redditRefresh_opensOverlayAndSpeaksRefreshing() {
        let h = makeHandler()
        var openedOverlays = [OverlayKind]()
        var spokenTexts    = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { openedOverlays.append($0) }

        _ = h.handle(.redditRefresh)

        XCTAssertTrue(openedOverlays.contains(.reddit))
        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - redditOpenIndex with no posts

    @MainActor
    func test_redditOpenIndex_withNoPosts_speaksNotFound() {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { _ in }

        _ = h.handle(.redditOpenIndex(index: 99))

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - summariseText (public API used by RedditOverlayView)

    @MainActor
    func test_summariseText_withLLMDisabled_returnsNil() async {
        let h = makeHandler() // router.mode = .disabled
        let result = await h.summariseText(
            title: "Test post",
            body:  "Some content here.",
            kind:  .post
        )
        XCTAssertNil(result, "summariseText should return nil when LLM is disabled")
    }
}
