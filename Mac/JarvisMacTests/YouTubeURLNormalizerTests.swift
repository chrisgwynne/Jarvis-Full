import XCTest
@testable import JarvisMac

/// Pins down the URL shapes the live-news player must handle.  The bug
/// these tests guard against is the one where "watch news" used to land
/// on the regular YouTube site and show a cookie / sign-in page — any
/// regression in the normalizer brings that bug back.
final class YouTubeURLNormalizerTests: XCTestCase {

    // MARK: - watch / youtu.be / embed / shorts / live conversion

    func test_watchURL_convertsToEmbed() {
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        guard case .embed(let url, let videoId) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertEqual(videoId, "dQw4w9WgXcQ")
        XCTAssertTrue(url.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"),
            "embed URL must use youtube-nocookie host with video id path. Got: \(url)")
    }

    func test_youtuBeShortLink_convertsToEmbed() {
        let r = YouTubeURLNormalizer.normalize("https://youtu.be/dQw4w9WgXcQ")
        guard case .embed(_, let videoId) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertEqual(videoId, "dQw4w9WgXcQ")
    }

    func test_embedURL_isPassthroughToNocookieHost() {
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/embed/dQw4w9WgXcQ")
        guard case .embed(let url, _) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertTrue(url.contains("youtube-nocookie.com"))
        XCTAssertTrue(url.contains("/embed/dQw4w9WgXcQ"))
    }

    func test_shortsURL_convertsToEmbed() {
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/shorts/dQw4w9WgXcQ")
        guard case .embed(_, let videoId) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertEqual(videoId, "dQw4w9WgXcQ")
    }

    func test_liveVideoURL_convertsToEmbed() {
        // /live/VIDEOID — finished live broadcast VOD form
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/live/dQw4w9WgXcQ")
        guard case .embed(_, let videoId) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertEqual(videoId, "dQw4w9WgXcQ")
    }

    // MARK: - live_stream by channel ID

    func test_embedLiveStreamByChannelId_isAccepted() {
        let r = YouTubeURLNormalizer.normalize(
            "https://www.youtube.com/embed/live_stream?channel=UC16niRr50-MSBwiO3YDb3RA")
        guard case .embed(let url, let videoId) = r else {
            return XCTFail("expected .embed, got \(r)")
        }
        XCTAssertNil(videoId)
        XCTAssertTrue(url.contains("youtube-nocookie.com"))
        XCTAssertTrue(url.contains("channel=UC16niRr50-MSBwiO3YDb3RA"))
        XCTAssertTrue(url.contains("autoplay=1"))
        XCTAssertTrue(url.contains("mute=1"))
    }

    // MARK: - The bug class — channel handle URLs must NOT silently fall through

    func test_channelHandleLive_returnsNeedsConfiguration() {
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/@BBCNews/live")
        if case .needsConfiguration(let reason, let msg) = r {
            XCTAssertEqual(reason, "channel_handle_no_id",
                "Should surface channel_handle_no_id, got \(reason)")
            XCTAssertTrue(msg.contains("embeddable"),
                "User message should mention 'embeddable'. Got: \(msg)")
        } else {
            XCTFail("Channel handle /live MUST NOT fall through to loading the real YouTube page. Got: \(r)")
        }
    }

    func test_channelHandleRoot_returnsNeedsConfiguration() {
        let r = YouTubeURLNormalizer.normalize("https://www.youtube.com/@BBCNews")
        if case .needsConfiguration = r { return }
        XCTFail("Channel handle root must return needsConfiguration")
    }

    func test_channelById_returnsNeedsConfiguration() {
        let r = YouTubeURLNormalizer.normalize(
            "https://www.youtube.com/channel/UC16niRr50-MSBwiO3YDb3RA")
        if case .needsConfiguration = r { return }
        XCTFail("Bare channel/ID path needs embed-form configuration")
    }

    // MARK: - iframe snippet extraction

    func test_iframeSnippet_extractsSrcAndNormalises() {
        let snippet = """
        <iframe width="560" height="315" \
        src="https://www.youtube.com/embed/dQw4w9WgXcQ" \
        title="YouTube video player" frameborder="0" \
        allow="autoplay; encrypted-media" allowfullscreen></iframe>
        """
        let r = YouTubeURLNormalizer.normalize(snippet)
        guard case .embed(let url, let videoId) = r else {
            return XCTFail("expected .embed from iframe snippet, got \(r)")
        }
        XCTAssertEqual(videoId, "dQw4w9WgXcQ")
        XCTAssertTrue(url.contains("youtube-nocookie.com"))
    }

    func test_iframeSnippet_withSingleQuotes() {
        let snippet = "<iframe src='https://www.youtube.com/embed/dQw4w9WgXcQ'></iframe>"
        let r = YouTubeURLNormalizer.normalize(snippet)
        guard case .embed = r else {
            return XCTFail("single-quoted iframe src must be extracted")
        }
    }

    // MARK: - Non-YouTube and malformed inputs

    func test_nonYouTubeURL_returnsNotYouTube() {
        let r = YouTubeURLNormalizer.normalize("https://www.bbc.co.uk/news/live")
        if case .notYouTube = r { return }
        XCTFail("Non-YouTube URL must return .notYouTube")
    }

    func test_emptyInput_returnsNeedsConfiguration() {
        let r = YouTubeURLNormalizer.normalize("")
        if case .needsConfiguration = r { return }
        XCTFail("Empty input must return .needsConfiguration")
    }

    func test_garbageURL_returnsNeedsConfiguration() {
        let r = YouTubeURLNormalizer.normalize("htp:/nope nope nope")
        if case .needsConfiguration = r { return }
        if case .notYouTube = r { return } // either is acceptable — never .embed
        XCTFail("Garbage input must not produce an embed URL. Got: \(r)")
    }

    // MARK: - Build URL params

    func test_embedURL_includesAutoplayMutePlaysInlineAndJSAPI() {
        let url = YouTubeURLNormalizer.buildEmbedURL(videoId: "abc12345678")
        XCTAssertTrue(url.contains("autoplay=1"))
        // mute=1 is now hardcoded — WKWebView refuses to autoplay with
        // sound on cold load.  LiveNewsPlayerView's host HTML unmutes
        // via the YouTube IFrame Player API postMessage immediately
        // after load, so the user experience is "starts with sound".
        XCTAssertTrue(url.contains("mute=1"),
            "URL must always carry mute=1 so YouTube honours autoplay. Sound is restored client-side via postMessage.")
        XCTAssertTrue(url.contains("playsinline=1"))
        XCTAssertTrue(url.contains("enablejsapi=1"),
            "enablejsapi=1 is required for the postMessage unMute() call to take effect.")
    }

    func test_embedURL_canDisableAutoplay() {
        // The `muted` parameter is now ignored (always-mute-on-URL +
        // postMessage unmute) — only `autoplay` is honoured here.
        let url = YouTubeURLNormalizer.buildEmbedURL(videoId: "abc12345678",
                                                     autoplay: false,
                                                     muted: false)
        XCTAssertTrue(url.contains("autoplay=0"))
        XCTAssertTrue(url.contains("mute=1"),
            "Even when caller asks for muted=false, URL stays mute=1; the host page unmutes via JS API.")
    }

    // MARK: - Source-type classifier (used by diagnostic logs)

    func test_sourceType_classifiesCorrectly() {
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://youtu.be/x"),                              "youtu_be")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://www.youtube.com/watch?v=x"),               "watch")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://www.youtube.com/embed/x"),                 "embed_video")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://www.youtube.com/embed/live_stream?channel=x"), "embed_live_stream")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://www.youtube.com/@BBCNews/live"),           "handle_live")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "<iframe src='...'></iframe>"),                     "iframe_html")
        XCTAssertEqual(YouTubeURLNormalizer.sourceType(for: "https://www.bbc.co.uk/news"),                      "non_youtube")
    }

    // MARK: - Video ID validation

    func test_validVideoId_isExactly11AlphanumericUnderscoreOrDash() {
        XCTAssertTrue(YouTubeURLNormalizer.isValidVideoId("dQw4w9WgXcQ"))
        XCTAssertTrue(YouTubeURLNormalizer.isValidVideoId("abcDEF12_-3"))
        XCTAssertFalse(YouTubeURLNormalizer.isValidVideoId("too_short"))
        XCTAssertFalse(YouTubeURLNormalizer.isValidVideoId("way_too_long_id_here"))
        XCTAssertFalse(YouTubeURLNormalizer.isValidVideoId("has spaces!"))
        XCTAssertFalse(YouTubeURLNormalizer.isValidVideoId(""))
    }
}
