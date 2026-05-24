import XCTest
@testable import JarvisMac

final class GitHubIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> GitHubIntentHandler {
        let prefs    = PreferencesStore()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return GitHubIntentHandler(renderer: renderer, prefs: prefs)
    }

    // MARK: - Return value

    @MainActor
    func test_githubIntents_returnTrue() {
        let h = makeHandler()
        h.speak       = { _ in }
        h.openOverlay = { _ in }
        h.getModule   = { nil }

        let intents: [Intent] = [
            .showGitHubOverlay,
            .checkGitHub,
            .githubDashboard,
            .githubListPRs(repo: nil),
            .githubReviewPR(repo: nil, number: nil),
            .githubOpenPR,
            .githubStalePRs(repo: nil),
            .githubListIssues(repo: nil),
            .githubStaleIssues(repo: nil),
            .githubCreateIssue(repo: nil, title: nil),
            .githubRecentCommits(repo: nil),
            .githubChangesToday(repo: nil),
            .githubChangesSince(repo: nil, days: 7),
            .githubCheckCI(repo: nil),
            .githubListMyRepos,
            .githubActiveRepos,
            .githubNeglectedRepos,
            .githubCreateRepo(name: nil),
            .githubDescribeRepo(repo: nil),
            .githubProjectStatus(repo: nil),
            .githubCodeReview(repo: nil),
            .githubSummariseDiff(repo: nil),
            .githubLocalStats(repo: nil),
        ]
        for intent in intents {
            XCTAssertTrue(h.handle(intent), "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonGitHubIntent_returnsFalse() {
        let h = makeHandler()
        h.speak       = { _ in }
        h.openOverlay = { _ in }

        XCTAssertFalse(h.handle(.showCalendar))
        XCTAssertFalse(h.handle(.shopifyOrders))
    }

    // MARK: - showGitHubOverlay

    @MainActor
    func test_showGitHubOverlay_opensOverlayAndSpeaks() {
        let h = makeHandler()
        var openedOverlays = [OverlayKind]()
        var spokenTexts    = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { openedOverlays.append($0) }

        _ = h.handle(.showGitHubOverlay)

        XCTAssertEqual(openedOverlays, [.github])
        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - Not-configured guard (no module)

    @MainActor
    func test_githubListPRs_withNoModule_speaksNotConfigured() {
        let h = makeHandler()
        h.getModule = { nil }
        var spokenTexts = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { _ in }

        _ = h.handle(.githubListPRs(repo: nil))

        // executeTask fires a Task; flush main queue
        let exp = expectation(description: "task fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - checkGitHub with no token

    @MainActor
    func test_checkGitHub_withNoToken_speaksNotConfigured() {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { _ in }

        _ = h.handle(.checkGitHub)

        // checkGitHub fires a Task
        let exp = expectation(description: "task fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - githubLocalStats (sync path, no module)

    @MainActor
    func test_githubLocalStats_withNoModule_speaksNotConfigured() {
        let h = makeHandler()
        h.getModule = { nil }
        var spokenTexts = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { _ in }

        _ = h.handle(.githubLocalStats(repo: nil))

        XCTAssertFalse(spokenTexts.isEmpty)
    }
}
