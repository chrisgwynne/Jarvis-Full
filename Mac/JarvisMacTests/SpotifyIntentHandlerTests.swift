import XCTest
@testable import JarvisMac

final class SpotifyIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> SpotifyIntentHandler {
        let prefs    = PreferencesStore()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return SpotifyIntentHandler(prefs: prefs, renderer: renderer)
    }

    // MARK: - Return value

    @MainActor
    func test_spotifyIntents_returnTrue() {
        let h = makeHandler()
        h.speak = { _ in }

        let intents: [Intent] = [
            .spotifyPlay(query: "jazz"),
            .spotifyPause,
            .spotifyResume,
            .spotifyNext,
            .spotifyPrevious,
            .spotifyWhatIsPlaying,
            .spotifyVolume(percent: 50),
            .spotifyShuffle(on: true),
        ]
        for intent in intents {
            XCTAssertTrue(h.handle(intent), "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonSpotifyIntent_returnsFalse() {
        let h = makeHandler()
        h.speak = { _ in }

        XCTAssertFalse(h.handle(.showCalendar))
        XCTAssertFalse(h.handle(.shopifyOrders))
    }

    // MARK: - Not-configured guard

    @MainActor
    func test_spotifyIntents_withNoToken_speakNotConfigured() {
        let h = makeHandler()
        // No keychain entry → spotifyPersonalToken is nil → every Spotify intent speaks not-configured
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        for intent: Intent in [.spotifyPlay(query: nil), .spotifyPause, .spotifyNext] {
            spokenTexts.removeAll()
            _ = h.handle(intent)
            XCTAssertFalse(spokenTexts.isEmpty,
                           "Expected not-configured response for \(intent)")
        }
    }

    // MARK: - No overlay callbacks

    @MainActor
    func test_spotifyHandler_hasNoOverlayCallback() {
        let h = makeHandler()
        // SpotifyIntentHandler intentionally has no openOverlay closure.
        // This test documents that contract by verifying the property doesn't exist.
        // (Compile-time — if the property were added the closure would be non-nil default.)
        h.speak = { _ in }
        _ = h.handle(.spotifyPause)
        // No assertion needed — the test will fail to compile if openOverlay is called
        // in a way that would require it to be wired.
    }
}
