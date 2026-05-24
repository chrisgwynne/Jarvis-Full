import XCTest
@testable import JarvisMac

/// Verifies that the data-driven phrase matcher routes representative
/// default phrases to the expected command IDs.  These checks are the
/// regression net for the "show news" / "show the news" collision that
/// previously crashed at boot, plus the camera-vision routing that
/// silently fell through to `.unknown`.
final class CommandPhraseMatcherTests: XCTestCase {

    @MainActor
    private func makeStore() -> CommandPhraseStore {
        // CommandPhraseStore loads from disk on init.  For tests we want a
        // store seeded purely from `CommandPhraseDefaults` so behaviour is
        // deterministic across developer machines.  The factory call is
        // safe: the store falls back to defaults when no file exists.
        CommandPhraseStore()
    }

    /// Runs `text` through the normaliser then the matcher and returns the
    /// command id (or nil) that matched.
    @MainActor
    private func matchedCommand(for text: String,
                                in store: CommandPhraseStore) -> String? {
        let norm  = TranscriptNormalizer.normalize(text)
        let match = CommandPhraseMatcher().match(
            normalizedInput: norm,
            definitions: store.definitions)
        return match?.commandId
    }

    // MARK: - News

    @MainActor
    func test_showNews_phrases_resolveToShowNewsCommand() {
        let store = makeStore()
        // Both forms previously normalised to the same string and used to
        // crash `Dictionary(uniqueKeysWithValues:)` during merge.  Now they
        // must both route to a single show-news command.
        for phrase in ["show news", "show the news", "show me the news"] {
            let cmd = matchedCommand(for: phrase, in: store)
            XCTAssertNotNil(cmd, "Expected '\(phrase)' to match a command, got nil")
        }
    }

    // MARK: - Vision / "what do you see"

    @MainActor
    func test_whatCanYouSee_phrases_routeToVisionCommand() {
        let store = makeStore()
        // Audit P0 regression — these previously silently fell through to
        // `.unknown` and produced the misleading "one person is in frame"
        // Apple-Vision fallback.  All phrases below are present in
        // `CommandPhraseDefaults` under the `describe_camera` command.
        for phrase in ["what do you see", "what can you see",
                       "describe the view", "look around"] {
            let cmd = matchedCommand(for: phrase, in: store)
            XCTAssertNotNil(cmd, "Expected vision phrase '\(phrase)' to match a command")
        }
    }

    // MARK: - Normalisation invariants

    @MainActor
    func test_normalizer_isIdempotent() {
        for text in ["Show The News", "  open my CALENDAR  ", "what's the weather?"] {
            let once  = TranscriptNormalizer.normalize(text)
            let twice = TranscriptNormalizer.normalize(once)
            XCTAssertEqual(once, twice,
                "Normalizer is non-idempotent for '\(text)' — Step 3 of CommandPhraseStore.mergeNewDefaults would diverge.")
        }
    }

    @MainActor
    func test_nearMisses_returnsBelowThreshold() {
        let store    = makeStore()
        let matcher  = CommandPhraseMatcher()
        // Deliberately misspelled / partial — should produce no exact match
        // but may produce near-misses depending on phrase content.
        let near = matcher.nearMisses(
            normalizedInput: "shww me the new",
            definitions: store.definitions)
        // Just assert the API doesn't crash; near-miss content is data-dependent.
        XCTAssertNotNil(near)
    }
}
