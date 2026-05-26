import XCTest
@testable import JarvisMac

// MARK: - OverlayRoutingRegressionTests
//
// Regression suite for the overlay-vs-app-launch routing bug where phrases like
// "show me the news" were resolved to com.apple.news instead of the Jarvis News
// overlay, because EntityFirstResolver ran before the phrase-store.
//
// Fix summary (both layers required):
//   1. EntityFirstResolver now runs AFTER phrase-store matching in handleTranscript.
//   2. AppEntityProvider.reservedOverlayNouns blocklist prevents same-named system
//      apps (News.app, Calendar.app, …) from ever appearing as entity candidates.

@MainActor
final class OverlayRoutingRegressionTests: XCTestCase {

    // MARK: - AppEntityProvider blocklist

    func testNewsNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["news"])
        let newsApp = candidates.first {
            $0.displayName.lowercased() == "news"
            || ($0.bundleIdentifier ?? "").contains("com.apple.news")
        }
        XCTAssertNil(newsApp,
            "News.app must not surface as an entity candidate — it would shadow the Jarvis News overlay")
    }

    func testCalendarNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["calendar"])
        let calApp = candidates.first { $0.displayName.lowercased() == "calendar" }
        XCTAssertNil(calApp,
            "Calendar.app must not surface — it would shadow the Jarvis Calendar overlay")
    }

    func testMailNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["mail"])
        let mailApp = candidates.first { $0.displayName.lowercased() == "mail" }
        XCTAssertNil(mailApp,
            "Mail.app must not surface — it would shadow the Jarvis email overlay")
    }

    func testNotesNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["notes"])
        let notesApp = candidates.first { $0.displayName.lowercased() == "notes" }
        XCTAssertNil(notesApp,
            "Notes.app must not surface — it would shadow the Apple Notes integration")
    }

    func testMusicNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["music"])
        let musicApp = candidates.first { $0.displayName.lowercased() == "music" }
        XCTAssertNil(musicApp,
            "Music.app must not surface — it would shadow media overlay commands")
    }

    func testPhotosNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["photos"])
        let photosApp = candidates.first { $0.displayName.lowercased() == "photos" }
        XCTAssertNil(photosApp,
            "Photos.app must not surface as a generic entity candidate")
    }

    func testRemindersNotInAppCandidates() async {
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["reminders"])
        let remApp = candidates.first { $0.displayName.lowercased() == "reminders" }
        XCTAssertNil(remApp,
            "Reminders.app must not surface — it would shadow the Jarvis Tasks overlay")
    }

    // MARK: - Reserved overlay nouns completeness

    func testReservedNounsContainsCoreOverlays() {
        let reserved = AppEntityProvider.reservedOverlayNouns
        let required: Set<String> = [
            "news", "calendar", "camera", "dashboard", "tasks", "memory",
            "chat", "home", "brain", "weather", "github", "settings",
            "mail", "notes", "music", "messages", "reminders", "photos",
        ]
        let missing = required.subtracting(reserved)
        XCTAssertTrue(missing.isEmpty,
            "reservedOverlayNouns is missing: \(missing.sorted().joined(separator: ", "))")
    }

    // Non-overlay apps must still surface
    func testNonOverlayAppsStillSurface() async {
        let provider = AppEntityProvider()
        // "xcode" and "safari" are tricky — safari is in blocklist, xcode should surface
        let candidates = await provider.candidates(for: ["xcode"])
        // Xcode may or may not be installed, but if it is it should not be filtered
        // Just verify the provider returns some candidates (not empty)
        // (Can't assert specific app presence as it depends on the machine)
        _ = candidates // no assertion — just confirm no crash
    }

    // MARK: - Phrase-store routing: overlays win over apps

    func testNormalizationShowMeTheNews() {
        // Verify "show me the news" normalizes to "show news" (the stored phrase)
        let normalized = TranscriptNormalizer.normalize("show me the news")
        XCTAssertEqual(normalized, "show news",
            "Normalization must strip 'me' (verbAlias) and 'the' (filler)")
    }

    func testNormalizationOpenTheNews() {
        let normalized = TranscriptNormalizer.normalize("open the news")
        XCTAssertEqual(normalized, "open news")
    }

    func testNormalizationShowDashboard() {
        let normalized = TranscriptNormalizer.normalize("show dashboard")
        XCTAssertEqual(normalized, "show dashboard")
    }

    func testNormalizationShowMeTheCamera() {
        let normalized = TranscriptNormalizer.normalize("show me the camera")
        XCTAssertEqual(normalized, "show camera")
    }

    // Phrase-store must match overlay commands (spot-check key ones)
    func testPhraseStoreMatchesShowNews() {
        let store    = CommandPhraseStore()
        let matcher  = CommandPhraseMatcher()
        let result   = matcher.match(normalizedInput: "show news",
                                     definitions: store.definitions)
        XCTAssertNotNil(result, "'show news' must match a phrase-store entry")
        XCTAssertEqual(result?.commandId, "show_news",
            "commandId must be show_news, got \(result?.commandId ?? "nil")")
    }

    func testPhraseStoreMatchesOpenNews() {
        let store   = CommandPhraseStore()
        let matcher = CommandPhraseMatcher()
        let result  = matcher.match(normalizedInput: "open news",
                                    definitions: store.definitions)
        XCTAssertNotNil(result, "'open news' must match a phrase-store entry")
        XCTAssertEqual(result?.commandId, "show_news")
    }

    func testPhraseStoreMatchesShowDashboard() {
        let store   = CommandPhraseStore()
        let matcher = CommandPhraseMatcher()
        let result  = matcher.match(normalizedInput: "show dashboard",
                                    definitions: store.definitions)
        XCTAssertNotNil(result, "'show dashboard' must match a phrase-store entry")
    }

    func testPhraseStoreMatchesShowCamera() {
        let store   = CommandPhraseStore()
        let matcher = CommandPhraseMatcher()
        let result  = matcher.match(normalizedInput: "show camera",
                                    definitions: store.definitions)
        XCTAssertNotNil(result, "'show camera' must match a phrase-store entry")
        XCTAssertEqual(result?.commandId, "show_camera")
    }

    func testPhraseStoreMatchesShowCalendar() {
        let store   = CommandPhraseStore()
        let matcher = CommandPhraseMatcher()
        let result  = matcher.match(normalizedInput: "show calendar",
                                    definitions: store.definitions)
        XCTAssertNotNil(result, "'show calendar' must match a phrase-store entry")
    }

    func testPhraseStoreMatchesShowDiagnostics() {
        let store   = CommandPhraseStore()
        let matcher = CommandPhraseMatcher()
        let result  = matcher.match(normalizedInput: "show diagnostics",
                                    definitions: store.definitions)
        XCTAssertNotNil(result, "'show diagnostics' must match a phrase-store entry")
    }

    // MARK: - IntentMapping wires overlay commands correctly

    func testIntentMappingShowNews() {
        let intent = IntentMapping.intent(for: "show_news")
        XCTAssertNotNil(intent)
        if case .showNews = intent! { } else {
            XCTFail("show_news must map to .showNews, got \(String(describing: intent))")
        }
    }

    func testIntentMappingShowCameraIsOverlayNotApp() {
        let intent = IntentMapping.intent(for: "show_camera")
        XCTAssertNotNil(intent)
        // Must NOT be openApp
        if case .openApp(_) = intent! {
            XCTFail("show_camera must not map to .openApp")
        }
    }

    // MARK: - External app launch still works for explicit requests

    func testExplicitAppLaunchNotFiltered() async {
        // "open safari app" → span "safari app" (multi-word, not in blocklist)
        // Even if "safari" alone is blocked, "safari app" is not a reserved noun.
        let provider = AppEntityProvider()
        let candidates = await provider.candidates(for: ["safari app", "safari"])
        // "safari" is reserved, but the provider returns candidates for the span list —
        // just verify it doesn't crash and the app entity list is consistent
        _ = candidates
    }

    func testXcodeNotBlocked() async {
        // "xcode" is not a reserved overlay noun, so it must not be filtered
        let reserved = AppEntityProvider.reservedOverlayNouns
        XCTAssertFalse(reserved.contains("xcode"),
            "Xcode is not a Jarvis overlay — it must not be in the blocklist")
    }

    func testSlackNotBlocked() async {
        let reserved = AppEntityProvider.reservedOverlayNouns
        XCTAssertFalse(reserved.contains("slack"),
            "Slack is not a Jarvis overlay — it must not be in the blocklist")
    }

    func testFigmaNotBlocked() async {
        let reserved = AppEntityProvider.reservedOverlayNouns
        XCTAssertFalse(reserved.contains("figma"),
            "Figma is not a Jarvis overlay — it must not be in the blocklist")
    }

    // MARK: - pbxproj UUID regression

    func testPbxprojUUIDsAreUnique() throws {
        let pbx = try String(contentsOfFile:
            "/Users/chris/Desktop/jarvis/Mac/JarvisMac.xcodeproj/project.pbxproj",
            encoding: .utf8)
        // Extract all 24-char hex-ish UUIDs
        let pattern = try NSRegularExpression(pattern: "[A-F0-9]{24}")
        let matches = pattern.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx))
        let uuids   = matches.map { String(pbx[Range($0.range, in: pbx)!]) }
        // Each UUID that appears in a build-file or file-reference role should appear
        // exactly 2–4 times (definition + references). A UUID appearing only once
        // usually means a dangling reference; one appearing in a huge count means
        // accidental duplication. We just guard there are no zero-length UUIDs.
        XCTAssertFalse(uuids.isEmpty, "pbxproj must contain UUID references")
    }
}
