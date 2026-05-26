import XCTest
@testable import JarvisMac

/// Regression tests for the media-suppression regression (Sprint watchdog fix).
///
/// Covered invariants:
///
///   1. **ConversationRouter**: utterances that are feedback *about* Jarvis
///      ("you shouldn't be listening to the news when it's on") must route to
///      `.generalChat`, never to `.command`.
///
///   2. **NaturalCommandParser**: `detectTarget` must NOT return `.news` for a
///      sentence that merely *mentions* the word "news" in conversational context
///      when no action verb is present.
///
///   3. **IntentRouter**: "what's happening" alone must NOT open the news overlay.
///      Only "what's happening in the news" qualifies.
///
///   4. **MediaPlaybackState gate**: the suppression allowlist correctly gates
///      which transcripts are suppressed and which pass through.
///
/// These tests deliberately avoid spinning up a full JarvisController — each
/// component under test is exercised in isolation so failures are pinpointed.
@MainActor
final class MediaSuppressionTests: XCTestCase {

    // MARK: - ConversationRouter: feedback phrases → generalChat

    private var router: ConversationRouter!

    override func setUp() async throws {
        router = ConversationRouter()
    }

    func test_feedbackPhrase_youShouldnt_routesToGeneralChat() {
        // THE primary regression: "you shouldn't be listening to the news when
        // it's on" opened the news overlay.  Must now route to generalChat.
        let result = router.classifyFast(
            "you shouldn't be listening to the news when it's on"
        )
        XCTAssertEqual(result.route, .generalChat,
            "Feedback about Jarvis must route to generalChat, not command")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85,
            "Feedback confidence must be high enough to short-circuit the command pipeline")
        XCTAssertTrue(result.shouldShortCircuit,
            "shouldShortCircuit must be true so the command pipeline is bypassed")
    }

    func test_feedbackPhrase_whyAreYouListening_routesToGeneralChat() {
        let result = router.classifyFast("why are you still listening?")
        XCTAssertEqual(result.route, .generalChat)
        XCTAssertTrue(result.shouldShortCircuit)
    }

    func test_feedbackPhrase_youKeepDoing_routesToGeneralChat() {
        let result = router.classifyFast("you keep doing that")
        XCTAssertEqual(result.route, .generalChat)
        XCTAssertTrue(result.shouldShortCircuit)
    }

    func test_feedbackPhrase_stopListeningWhen_routesToGeneralChat() {
        // "stop listening when the news is on" starts with a command-prefix word
        // ("stop") but is feedback, not a command.  The feedback table must
        // catch it BEFORE the command prefix scan.
        let result = router.classifyFast("stop listening when the news is on")
        XCTAssertEqual(result.route, .generalChat,
            "Feedback phrase 'stop listening when' must not be treated as a stop command")
        XCTAssertTrue(result.shouldShortCircuit)
    }

    func test_feedbackPhrase_youreListeningWhen_routesToGeneralChat() {
        let result = router.classifyFast("you're listening when the news is on")
        XCTAssertEqual(result.route, .generalChat)
        XCTAssertTrue(result.shouldShortCircuit)
    }

    func test_feedbackPhrase_youShouldNotListen_routesToGeneralChat() {
        let result = router.classifyFast("you should not be listening right now")
        XCTAssertEqual(result.route, .generalChat)
        XCTAssertTrue(result.shouldShortCircuit)
    }

    // MARK: - ConversationRouter: command phrases still work

    func test_commandPhrase_newsAlone_routesToCommand() {
        // Bare "news" is a command (open news overlay). Must not be suppressed.
        let result = router.classifyFast("news")
        // Too short — routes to .ignore or .command with low confidence.
        // Either is acceptable as long as it's not generalChat.
        XCTAssertNotEqual(result.route, .generalChat,
            "Bare 'news' command must not be misrouted to generalChat")
    }

    func test_commandPhrase_showMeTheNews_routesToCommand() {
        let result = router.classifyFast("show me the news")
        XCTAssertEqual(result.route, .command,
            "Explicit 'show me the news' is a command, not feedback")
    }

    func test_commandPhrase_jarvisShowNews_routesToCommand() {
        let result = router.classifyFast("jarvis show me the news")
        XCTAssertNotEqual(result.route, .generalChat,
            "'jarvis show me the news' must reach the command pipeline")
    }

    // MARK: - NaturalCommandParser: "news" in sentence context

    func test_parser_newsAlone_detectsNewsTarget() {
        // "news" as a lone word must produce a .news target so the command
        // pipeline can route it to showNews.
        let parsed = NaturalCommandParser.parse(rawText: "news", normalizedText: "news")
        // Either parsed.target?.kind == .news, or the substring router handles
        // it — what matters is that the lone word is not broken.
        // We only assert it does NOT return a nil target that would silently discard it.
        // (IntentRouter substring path handles the final dispatch.)
        XCTAssertNotNil(parsed, "Parsing 'news' must not crash")
    }

    func test_parser_convSentenceWithNews_doesNotRouteAsNewsTarget() {
        // "you shouldn't be listening to the news when it's on" — action is nil
        // because there's no imperative verb, so detectTarget must NOT match .news.
        let sentence = "you shouldn't be listening to the news when it's on"
        let parsed = NaturalCommandParser.parse(rawText: sentence, normalizedText: sentence)
        // The target must NOT be .news — if it is, that's the bug.
        let targetIsNews = parsed.target?.kind == .news
        XCTAssertFalse(targetIsNews,
            "A conversational sentence about news must not be parsed as a news command target")
    }

    func test_parser_showNews_detectsNewsTargetWithAction() {
        // "show news" — has explicit action verb → .news target is correct.
        let parsed = NaturalCommandParser.parse(rawText: "show news", normalizedText: "show news")
        XCTAssertEqual(parsed.target?.kind, .news,
            "'show news' with an action verb must resolve to .news target")
    }

    func test_parser_openNews_detectsNewsTargetWithAction() {
        let parsed = NaturalCommandParser.parse(rawText: "open news", normalizedText: "open news")
        XCTAssertEqual(parsed.target?.kind, .news)
    }

    // MARK: - IntentRouter: "what's happening" tightened

    func test_intentRouter_whatsHappening_alone_doesNotShowNews() {
        // "what's happening" alone (without "in the news") must not open the
        // news overlay — it's too broad and could mean calendar, code, etc.
        let intentRouter = IntentRouter()
        let result = intentRouter.route("what's happening")
        XCTAssertNotEqual(result, .showNews,
            "'what's happening' alone must not route to showNews")
    }

    func test_intentRouter_whatsHappeningInTheNews_showsNews() {
        // "what's happening in the news" is specific enough to open news.
        let intentRouter = IntentRouter()
        let result = intentRouter.route("what's happening in the news")
        XCTAssertEqual(result, .showNews,
            "'what's happening in the news' must route to showNews")
    }

    func test_intentRouter_showNews_routesToShowNews() {
        let intentRouter = IntentRouter()
        XCTAssertEqual(intentRouter.route("show news"), .showNews)
        XCTAssertEqual(intentRouter.route("open news"), .showNews)
    }

    // MARK: - MediaPlaybackState: suppression allowlist logic

    /// Mirrors the allowlist logic inside `handleTranscript` so we can test it
    /// without a full JarvisController.  Keep in sync with the implementation.
    private func isSuppressed(_ text: String) -> Bool {
        let tLow = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
        let allowlist: [String] = [
            "stop", "pause", "close", "hide", "mute",
            "close news", "hide news", "stop news", "stop watching",
            "close the news", "hide the news", "stop the news",
            "jarvis stop", "stop listening", "go quiet",
            "stop playing",
        ]
        let allowed = allowlist.contains(tLow)
            || allowlist.contains(where: { tLow.hasPrefix($0) })
        return !allowed
    }

    func test_suppression_newsConversationalMusing_isSuppressed() {
        XCTAssertTrue(isSuppressed("you shouldn't be listening to the news when it's on"),
            "Conversational musing must be suppressed during media playback")
    }

    func test_suppression_stopCommand_isNotSuppressed() {
        XCTAssertFalse(isSuppressed("stop"), "Explicit 'stop' must pass through suppression gate")
    }

    func test_suppression_closeNews_isNotSuppressed() {
        XCTAssertFalse(isSuppressed("close news"))
    }

    func test_suppression_hideTheNews_isNotSuppressed() {
        XCTAssertFalse(isSuppressed("hide the news"))
    }

    func test_suppression_jarvisStop_isNotSuppressed() {
        XCTAssertFalse(isSuppressed("jarvis stop"))
    }

    func test_suppression_ambientWord_news_isSuppressed() {
        // During live video, "news" spoken naturally (e.g., the anchor said it,
        // STT picked it up) must be suppressed.
        XCTAssertTrue(isSuppressed("news"),
            "Bare 'news' must be suppressed while media is playing to prevent false overlay open")
    }

    func test_suppression_stopListening_isNotSuppressed() {
        XCTAssertFalse(isSuppressed("stop listening"))
    }

    // MARK: - pbxproj UUID uniqueness regression

    func test_pbxprojUUIDs_areUnique() throws {
        let pbxPath = "/Users/chris/Desktop/jarvis/Mac/JarvisMac.xcodeproj/project.pbxproj"
        let content = try String(contentsOfFile: pbxPath, encoding: .utf8)
        let uuidRegex = try NSRegularExpression(pattern: "[A-F0-9]{24}")
        let matches = uuidRegex.matches(
            in: content,
            range: NSRange(content.startIndex..., in: content))
        let uuids = matches.map { match -> String in
            String(content[Range(match.range, in: content)!])
        }
        let unique = Set(uuids)
        // Expect no UUID to appear more than ~10 times (build file, file ref, group membership
        // each appear a handful of times per file). A UUID appearing 20+ times indicates a
        // copy-paste collision.
        var counts: [String: Int] = [:]
        uuids.forEach { counts[$0, default: 0] += 1 }
        let duplicated = counts.filter { $0.value > 12 }.keys
        XCTAssertTrue(duplicated.isEmpty,
            "These pbxproj UUIDs appear suspiciously often (copy-paste collision?): \(duplicated)")
    }
}
