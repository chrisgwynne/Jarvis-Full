import XCTest
@testable import JarvisMac

/// Pins down the watch-news listening-pause rule.  Three invariants:
///
///   1. `MediaPlaybackState.isPlaying` returns true only for `.playing(_)`.
///   2. `displayLabel` includes the channel for the playing/paused cases
///      so diagnostic logs identify which stream paused listening.
///   3. The cases are `Equatable` — the `enterMediaPlayback` no-op-on-
///      same-channel optimisation depends on this.
///
/// We don't spin up a full JarvisController in these tests — the
/// listening-pause guard inside `startConversationalListening` is a
/// single `if state.mediaPlaybackState.isPlaying { return }` and the
/// state value is the contract.  Integration tests for the controller
/// path are covered by the existing listening-lifecycle test plan.
@MainActor
final class MediaPlaybackStateTests: XCTestCase {

    func test_inactive_isNotPlaying() {
        XCTAssertFalse(MediaPlaybackState.inactive.isPlaying)
    }

    func test_playing_isPlaying_andCarriesChannel() {
        let s: MediaPlaybackState = .playing(channel: "BBC News")
        XCTAssertTrue(s.isPlaying)
        XCTAssertTrue(s.displayLabel.contains("BBC News"))
    }

    func test_paused_isNotPlaying() {
        XCTAssertFalse(MediaPlaybackState.paused(channel: "Sky News").isPlaying)
    }

    func test_stopped_isNotPlaying() {
        XCTAssertFalse(MediaPlaybackState.stopped.isPlaying)
    }

    func test_equality_distinguishesChannels() {
        // Two `.playing` states with different channels must not be equal
        // — otherwise `enterMediaPlayback`'s "no-op on same channel"
        // optimisation would erroneously skip a real channel switch.
        XCTAssertEqual(MediaPlaybackState.playing(channel: "BBC"),
                       MediaPlaybackState.playing(channel: "BBC"))
        XCTAssertNotEqual(MediaPlaybackState.playing(channel: "BBC"),
                          MediaPlaybackState.playing(channel: "Sky"))
        XCTAssertNotEqual(MediaPlaybackState.playing(channel: "BBC"),
                          MediaPlaybackState.inactive)
    }

    func test_newsOverlayMode_defaultIsHeadlines() {
        let s = AppState()
        XCTAssertEqual(s.newsOverlayMode, .headlines,
            "Default mode must be `.headlines` so a fresh launch doesn't try to autoplay a channel.")
        XCTAssertEqual(s.mediaPlaybackState, .inactive)
    }

    func test_setMediaPlaying_thenInactive_recordsTransitions() {
        // The AppState fields the news pipeline writes — confirms the
        // value-type round-trip and that observers see the change.
        let s = AppState()
        s.mediaPlaybackState = .playing(channel: "BBC News")
        XCTAssertEqual(s.mediaPlaybackState, .playing(channel: "BBC News"))
        s.mediaPlaybackState = .inactive
        XCTAssertEqual(s.mediaPlaybackState, .inactive)
    }

    func test_channelLoadStatus_dictionaryRoundTrips() {
        // `LiveNewsPlayerView` writes per-channel statuses here — the
        // watch-mode selector reads them to show the blocked / failed /
        // playing badges.
        let s = AppState()
        XCTAssertNil(s.newsChannelLoadStatus["bbc_news_live"])
        s.newsChannelLoadStatus["bbc_news_live"] = "blocked"
        s.newsChannelLastError["bbc_news_live"]  = "sign_in"
        XCTAssertEqual(s.newsChannelLoadStatus["bbc_news_live"], "blocked")
        XCTAssertEqual(s.newsChannelLastError["bbc_news_live"],  "sign_in")
    }
}
