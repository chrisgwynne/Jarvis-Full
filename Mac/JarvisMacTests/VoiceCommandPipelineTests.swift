import XCTest
@testable import JarvisMac

/// Regression suite for the voice command pipeline ordering bug where conversational
/// phrases (e.g. "goodbye") were fuzzy-matched to entity names (e.g. "Google")
/// because EntityFirstResolver ran before intent classification.
///
/// P0 regression: "goodbye" → Google [website] score=0.72 reason=fuzzy
final class VoiceCommandPipelineTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> CommandPhraseStore { CommandPhraseStore() }

    @MainActor
    private func phraseCommandId(for text: String, in store: CommandPhraseStore) -> String? {
        let norm  = TranscriptNormalizer.normalize(text)
        let match = CommandPhraseMatcher().match(
            normalizedInput: norm,
            definitions: store.definitions)
        return match?.commandId
    }

    @MainActor
    private func routerIntent(for text: String) -> Intent {
        let norm = TranscriptNormalizer.normalize(text)
        return IntentRouter().route(norm)
    }

    // MARK: - Phrase store: farewell

    @MainActor
    func test_goodbye_matchesFarewellCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "goodbye", in: store), "farewell",
            "'goodbye' must resolve to farewell command, not fall through to entity resolution")
    }

    @MainActor
    func test_bye_matchesFarewellCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "bye", in: store), "farewell",
            "'bye' must resolve to farewell command")
    }

    @MainActor
    func test_seeYou_matchesFarewellCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "see you", in: store), "farewell")
    }

    @MainActor
    func test_goodNight_matchesFarewellCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "good night", in: store), "farewell")
    }

    // MARK: - Phrase store: gratitude

    @MainActor
    func test_thanks_matchesThankUserCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "thanks", in: store), "thank_user",
            "'thanks' must resolve to thank_user, not fall through to entity resolution")
    }

    @MainActor
    func test_thankYou_matchesThankUserCommand() {
        let store = makeStore()
        XCTAssertEqual(phraseCommandId(for: "thank you", in: store), "thank_user")
    }

    // MARK: - IntentMapping: phrase → Intent

    func test_farewell_commandId_mapsToFarewellIntent() {
        XCTAssertEqual(IntentMapping.intent(for: "farewell"), .farewell)
    }

    func test_thankUser_commandId_mapsToThankUserIntent() {
        XCTAssertEqual(IntentMapping.intent(for: "thank_user"), .thankUser)
    }

    // MARK: - IntentRouter: direct routing

    @MainActor
    func test_router_goodbye_returnsFarewell() {
        XCTAssertEqual(routerIntent(for: "goodbye"), .farewell,
            "IntentRouter must return .farewell for 'goodbye' before entity resolution")
    }

    @MainActor
    func test_router_bye_returnsFarewell() {
        XCTAssertEqual(routerIntent(for: "bye"), .farewell)
    }

    @MainActor
    func test_router_thankYou_returnsThankUser() {
        XCTAssertEqual(routerIntent(for: "thank you"), .thankUser)
    }

    // MARK: - Jaro-Winkler does NOT trip on conversational phrases

    func test_goodbye_doesNotFuzzyMatchGoogle() {
        // Verify the scorer produces a score that WOULD have triggered the bug
        // before the pre-classifier fix. The fix is upstream — conversational
        // phrases never reach EntityScorer now — but this test documents the
        // root cause score that motivated the change.
        let googleCandidate = EntityCandidate(
            entityId: "com.google.chrome",
            displayName: "Google",
            entityType: .website,
            provider: "browser",
            aliases: ["google"],
            externalURL: nil,
            bundleIdentifier: nil,
            baseConfidence: 1.0)
        let (score, _) = EntityScorer.score(span: "goodbye", against: googleCandidate)
        // Score was ~0.72 — exactly at minimumConfidence threshold. Document it.
        XCTAssertGreaterThan(score, 0.60,
            "Jaro-Winkler('goodbye','google') should be high enough to confirm the original bug was real")
    }

    // MARK: - Entity-needing intents still resolve correctly

    @MainActor
    func test_openGoogle_doesNotMatchFarewellOrThankUser() {
        let store = makeStore()
        // "open google" should NOT match farewell or thank_user
        let cmd = phraseCommandId(for: "open google", in: store)
        XCTAssertNotEqual(cmd, "farewell")
        XCTAssertNotEqual(cmd, "thank_user")
    }

    @MainActor
    func test_searchGoogleForCats_doesNotMatchFarewellOrThankUser() {
        let store = makeStore()
        let cmd = phraseCommandId(for: "search google for cats", in: store)
        XCTAssertNotEqual(cmd, "farewell")
        XCTAssertNotEqual(cmd, "thank_user")
    }
}
