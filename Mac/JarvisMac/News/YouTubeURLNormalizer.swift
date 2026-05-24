import Foundation

/// Converts various YouTube-shaped inputs into a canonical embed URL the
/// in-app WKWebView can load inside an `<iframe>` without triggering the
/// regular YouTube cookie/sign-in flow.
///
/// **Inputs accepted:**
///   * `https://www.youtube.com/watch?v=VIDEO_ID`              (regular)
///   * `https://youtu.be/VIDEO_ID`                              (short)
///   * `https://www.youtube.com/embed/VIDEO_ID`                 (already embed)
///   * `https://www.youtube.com/shorts/VIDEO_ID`                (shorts)
///   * `https://www.youtube.com/live/VIDEO_ID`                  (live VOD)
///   * `https://www.youtube.com/embed/live_stream?channel=CHANNEL_ID`
///   * Raw `<iframe …>` HTML snippet pasted by the user
///
/// **Inputs that fail with a clear error:**
///   * `https://www.youtube.com/@HANDLE/live`     (no extractable video ID)
///   * `https://www.youtube.com/@HANDLE`          (channel page only)
///   * non-YouTube URLs (caller routes elsewhere)
///
/// All results use `youtube-nocookie.com` — YouTube's documented
/// privacy-enhanced embed domain that suppresses tracking cookies
/// until the user interacts.  This is the specific control surface that
/// makes the cookie-consent banner not appear on first load.
enum YouTubeURLNormalizer {

    // MARK: - Public API

    /// Outcome of a normalization attempt.
    enum Result: Equatable {
        /// A clean iframe-ready URL on `youtube-nocookie.com`.
        case embed(url: String, videoId: String?)
        /// The input is a YouTube URL but doesn't carry an extractable video
        /// or channel ID (e.g. `@handle/live`).  Caller should surface the
        /// `userMessage` and offer "Open in browser" as a fallback.
        case needsConfiguration(reason: String, userMessage: String)
        /// Input is not a YouTube URL.  Caller may load it as a normal web page.
        case notYouTube
    }

    /// Try to convert `input` into an embed URL.  `input` may be a URL,
    /// a `youtu.be` short link, or a raw iframe snippet.
    static func normalize(_ input: String,
                          autoplay: Bool = true,
                          muted:    Bool = true) -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .needsConfiguration(
                reason: "empty_input",
                userMessage: "No channel URL configured.")
        }

        // If the user pasted a raw iframe snippet, recurse with the src.
        if let iframeSrc = extractIframeSrc(html: trimmed) {
            return normalize(iframeSrc, autoplay: autoplay, muted: muted)
        }

        guard let url = URL(string: trimmed) else {
            return .needsConfiguration(
                reason: "invalid_url",
                userMessage: "Channel URL is not a valid URL:\n\(trimmed)")
        }

        guard let host = url.host?.lowercased() else { return .notYouTube }

        // ── youtu.be/VIDEO_ID ────────────────────────────────────────────────
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            // The path is "/VIDEO_ID"; strip the leading slash.
            let id = String(url.path.dropFirst())
            if isValidVideoId(id) {
                return .embed(url: buildEmbedURL(videoId: id,
                                                  autoplay: autoplay,
                                                  muted: muted),
                              videoId: id)
            }
            return .needsConfiguration(
                reason: "youtu_be_missing_id",
                userMessage: "youtu.be link doesn't include a video ID.")
        }

        // ── youtube.com / youtube-nocookie.com / m.youtube.com ───────────────
        let isYouTubeHost =
            host == "youtube.com"          || host.hasSuffix(".youtube.com") ||
            host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        guard isYouTubeHost else { return .notYouTube }

        let path = url.path
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let qItems = comps?.queryItems ?? []

        // /watch?v=VIDEO_ID
        if path == "/watch", let v = qItems.first(where: { $0.name == "v" })?.value,
           isValidVideoId(v) {
            return .embed(url: buildEmbedURL(videoId: v,
                                              autoplay: autoplay,
                                              muted: muted),
                          videoId: v)
        }

        // /embed/live_stream?channel=CHANNEL_ID  (current-live for a channel)
        if path == "/embed/live_stream",
           let channelId = qItems.first(where: { $0.name == "channel" })?.value,
           !channelId.isEmpty {
            return .embed(url: buildLiveStreamEmbedURL(channelId: channelId,
                                                        autoplay: autoplay,
                                                        muted: muted),
                          videoId: nil)
        }

        // /embed/VIDEO_ID
        if path.hasPrefix("/embed/") {
            let id = String(path.dropFirst("/embed/".count))
            if isValidVideoId(id) {
                return .embed(url: buildEmbedURL(videoId: id,
                                                  autoplay: autoplay,
                                                  muted: muted),
                              videoId: id)
            }
        }

        // /shorts/VIDEO_ID
        if path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count))
            if isValidVideoId(id) {
                return .embed(url: buildEmbedURL(videoId: id,
                                                  autoplay: autoplay,
                                                  muted: muted),
                              videoId: id)
            }
        }

        // /live/VIDEO_ID  (the URL form for a finished live broadcast)
        if path.hasPrefix("/live/") {
            let id = String(path.dropFirst("/live/".count))
            if isValidVideoId(id) {
                return .embed(url: buildEmbedURL(videoId: id,
                                                  autoplay: autoplay,
                                                  muted: muted),
                              videoId: id)
            }
            // /@HANDLE/live and /channel/live both end up here without an ID.
            return .needsConfiguration(
                reason: "live_path_no_id",
                userMessage: "This channel URL needs an embeddable video ID or embed URL.")
        }

        // /@HANDLE/live  or  /@HANDLE  (no extractable ID)
        if path.hasPrefix("/@") || path.hasPrefix("/c/")
            || path.hasPrefix("/user/") || path.hasPrefix("/channel/") {
            return .needsConfiguration(
                reason: "channel_handle_no_id",
                userMessage: "This channel URL needs an embeddable video ID or embed URL.")
        }

        // Unrecognised YouTube path — surface a clear message instead of
        // silently loading the regular YouTube site.
        return .needsConfiguration(
            reason: "unrecognised_youtube_path",
            userMessage: "Unrecognised YouTube URL shape:\n\(trimmed)")
    }

    // MARK: - Diagnostics

    /// Short identifier for the detected source shape — used by
    /// diagnostic logs without leaking the full URL.
    static func sourceType(for input: String) -> String {
        let s = input.lowercased()
        if s.contains("<iframe")                     { return "iframe_html" }
        if s.contains("/embed/live_stream")          { return "embed_live_stream" }
        if s.contains("/embed/")                     { return "embed_video" }
        if s.contains("/watch?v=")                   { return "watch" }
        if s.contains("youtu.be/")                   { return "youtu_be" }
        if s.contains("/shorts/")                    { return "shorts" }
        if s.contains("/live/")                      { return "live_path" }
        if s.contains("/@") && s.contains("/live")   { return "handle_live" }
        if s.contains("/@")                          { return "handle" }
        if s.contains("youtube.com")                 { return "youtube_other" }
        return "non_youtube"
    }

    // MARK: - Builders

    /// `https://www.youtube-nocookie.com/embed/VIDEO_ID?…`
    ///
    /// The URL is always built with `mute=1` regardless of `muted` — that's
    /// what lets YouTube honour `autoplay=1` (browsers / WKWebView block
    /// unmuted autoplay on cold load).  `LiveNewsPlayerView` then posts an
    /// `unMute()` + `setVolume(100)` command to the iframe immediately
    /// after load via the IFrame Player API, giving the user audio with
    /// no extra click.  `enablejsapi=1` is what makes that postMessage
    /// route work.  `playsinline=1` keeps the player inside our WebView.
    static func buildEmbedURL(videoId: String,
                              autoplay: Bool = true,
                              muted: Bool = true) -> String {
        _ = muted   // Always start muted; LiveNewsPlayerView unmutes via JS API.
        let params = [
            "autoplay=\(autoplay ? 1 : 0)",
            "mute=1",
            "playsinline=1",
            "rel=0",
            "modestbranding=1",
            "enablejsapi=1",
        ].joined(separator: "&")
        return "https://www.youtube-nocookie.com/embed/\(videoId)?\(params)"
    }

    /// `https://www.youtube-nocookie.com/embed/live_stream?channel=…`
    static func buildLiveStreamEmbedURL(channelId: String,
                                         autoplay: Bool = true,
                                         muted: Bool = true) -> String {
        _ = muted
        let params = [
            "channel=\(channelId)",
            "autoplay=\(autoplay ? 1 : 0)",
            "mute=1",
            "playsinline=1",
            "rel=0",
            "modestbranding=1",
            "enablejsapi=1",
        ].joined(separator: "&")
        return "https://www.youtube-nocookie.com/embed/live_stream?\(params)"
    }

    // MARK: - Helpers

    /// YouTube video IDs are 11 chars of [A-Za-z0-9_-].
    static func isValidVideoId(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.allSatisfy { c in
            c.isLetter || c.isNumber || c == "_" || c == "-"
        }
    }

    /// Extracts `src="…"` from an `<iframe …>` snippet.  Returns nil if
    /// the input doesn't look like an iframe.
    private static func extractIframeSrc(html: String) -> String? {
        guard html.contains("<iframe") else { return nil }
        // Very small, tolerant scan — no XML parser needed for this.
        // Match src='…' or src="…".
        let patterns = ["src=\"", "src='"]
        for opener in patterns {
            guard let startRange = html.range(of: opener) else { continue }
            let afterOpen = startRange.upperBound
            let closer: Character = opener.last == "\"" ? "\"" : "'"
            if let endIdx = html[afterOpen...].firstIndex(of: closer) {
                let src = String(html[afterOpen..<endIdx]).trimmingCharacters(in: .whitespaces)
                if !src.isEmpty { return src }
            }
        }
        return nil
    }
}
