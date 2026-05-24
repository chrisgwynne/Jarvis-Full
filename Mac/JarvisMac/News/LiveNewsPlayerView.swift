import SwiftUI
import WebKit

/// Embedded live news / video player.
///
/// **YouTube load path (the only path that ever reaches youtube.com):**
///   1. `YouTubeURLNormalizer.normalize` converts whatever's in
///      `channel.url` (watch URL, youtu.be link, embed URL, channel ID,
///      iframe snippet) into an embed URL on `youtube-nocookie.com`.
///   2. We load a local HTML page containing a full-bleed `<iframe>`
///      whose `src` is that embed URL.
///   3. `baseURL` on the HTML load is `youtube-nocookie.com` so the
///      iframe has a same-origin parent and YouTube doesn't reject the
///      player with error 153.
///
/// **Why this avoids the cookie/sign-in wall:** the regular YouTube
/// channel page (`youtube.com/@HANDLE/live` etc.) presents a
/// `consent.youtube.com` interstitial on first load.  The embed-only
/// `youtube-nocookie.com/embed/…` path is YouTube's documented
/// privacy-enhanced player and does NOT.  This is exactly what
/// fixes the "watch news shows a sign-in page" bug.
///
/// **Fallback:** if the normalizer can't extract a usable embed (e.g.
/// the stored URL is `@HANDLE/live` with no video ID), the player
/// shows a clear "embed not possible" message + Open-in-browser button
/// instead of silently loading the regular site.
struct LiveNewsPlayerView: NSViewRepresentable {
    let channel: NewsChannel?
    /// Optional callback that publishes per-channel load status into
    /// `AppState.newsChannelLoadStatus` via `JarvisController`.
    /// `status` values: "loading", "playing", "blocked", "failed".
    /// Caller is responsible for the controller wiring; the view never
    /// reaches into JarvisController itself so it stays trivially
    /// previewable in SwiftUI canvases.
    var onLoadStatus: ((_ channelId: String, _ status: String, _ error: String?) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        // Dedicated video-friendly config.  Persistent (non-ephemeral)
        // websiteDataStore so the user's "I clicked play once" state is
        // remembered across overlay opens.  Same default identity that
        // `WKWebView()` uses, but spelled out for clarity.
        let cfg = WKWebViewConfiguration()
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Inline media playback — required so the player stays inside
        // the WKWebView frame instead of trying to enter system fullscreen.
        cfg.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")
        cfg.websiteDataStore = .default()

        // Inject CSS that hides chrome on the rare path that reaches
        // youtube.com pages (e.g. user manually configured a .webPage
        // channel pointing at a YouTube URL — we then surface a clear
        // fallback message rather than dumping them in the YT site).
        let script = WKUserScript(
            source: Self.zoomVideoScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        cfg.userContentController.addUserScript(script)

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = false
        // Identify as Safari — youtube-nocookie still does light UA
        // sniffing for the embed.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/17.0 Safari/605.1.15"
        // Opaque dark background — see comment in previous revision for the
        // WindowServer-compositing reason.
        web.setValue(true, forKey: "drawsBackground")
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor(red: 0.03, green: 0.05,
                                             blue: 0.09, alpha: 1.0).cgColor
        web.layer?.cornerRadius = 12
        web.layer?.masksToBounds = true
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard let channel else {
            if context.coordinator.lastLoadedSignature != "none" {
                context.coordinator.lastLoadedSignature = "none"
                web.loadHTMLString(Self.placeholderHTML(message: "No live channel selected."),
                                   baseURL: nil)
            }
            return
        }
        // Signature avoids reloading on no-op state ticks while still
        // reloading when kind/url change together.
        let signature = "\(channel.kind.rawValue)|\(channel.url)"
        guard context.coordinator.lastLoadedSignature != signature else { return }
        context.coordinator.lastLoadedSignature = signature
        context.coordinator.currentChannelName = channel.name
        context.coordinator.currentChannelId   = channel.id
        context.coordinator.currentRawURL = channel.url
        context.coordinator.onLoadStatus = onLoadStatus
        onLoadStatus?(channel.id, "loading", nil)

        Self.loadChannel(channel, into: web, coordinator: context.coordinator)
    }

    // MARK: - Routing

    /// Single chokepoint that decides what HTML / URL is loaded into
    /// the WKWebView.  Every channel — regardless of declared `kind` —
    /// is first inspected for a YouTube URL.  If it is YouTube, we
    /// route through `YouTubeURLNormalizer` and load the iframe HTML;
    /// the regular YouTube site never gets loaded directly.
    static func loadChannel(_ channel: NewsChannel,
                            into web: WKWebView,
                            coordinator: Coordinator) {
        // Iframe-snippet kind: pass the raw HTML straight through.
        if channel.kind == .iframeEmbed {
            Log.ui.info("news_embed kind=iframeEmbed channel=\(channel.name, privacy: .public)")
            // Wrap in a chrome-less host page so the snippet fills the view.
            let html = wrapIframeSnippet(channel.url)
            web.loadHTMLString(html,
                               baseURL: URL(string: "https://www.youtube-nocookie.com/"))
            return
        }

        // HLS kind: dedicated <video> wrapper.
        if channel.kind == .hls {
            Log.ui.info("news_embed kind=hls channel=\(channel.name, privacy: .public)")
            web.loadHTMLString(hlsHTML(streamURL: channel.url), baseURL: nil)
            return
        }

        // Try YouTube normalization for everything else (`.youtubeEmbed`,
        // `.webPage`, `.custom`).  If the channel's URL is YouTube-shaped,
        // we ALWAYS go through the embed path, regardless of `kind`.
        let normalization = YouTubeURLNormalizer.normalize(channel.url,
                                                            autoplay: true,
                                                            muted: true)
        let sourceType = YouTubeURLNormalizer.sourceType(for: channel.url)

        switch normalization {
        case .embed(let embedURL, let videoId):
            Log.ui.info("""
                news_embed kind=\(channel.kind.rawValue, privacy: .public) \
                channel=\(channel.name, privacy: .public) \
                source=\(sourceType, privacy: .public) \
                videoId=\(videoId ?? "—", privacy: .public) \
                embedHost=\(URL(string: embedURL)?.host ?? "?", privacy: .public) \
                iframe=true
                """)
            coordinator.lastEmbedURL = embedURL
            coordinator.lastFallbackOpenURL = nil
            let html = youtubeIframeHTML(embedURL: embedURL)
            web.loadHTMLString(html,
                               baseURL: URL(string: "https://www.youtube-nocookie.com/"))

        case .needsConfiguration(let reason, let userMessage):
            // Don't fall through to loading the real YouTube site — that
            // is exactly the bug.  Surface a clear, actionable message.
            Log.ui.warning("""
                news_embed_needs_config \
                channel=\(channel.name, privacy: .public) \
                source=\(sourceType, privacy: .public) \
                reason=\(reason, privacy: .public)
                """)
            coordinator.lastFallbackOpenURL = channel.url
            coordinator.onLoadStatus?(channel.id, "blocked", reason)
            web.loadHTMLString(
                fallbackHTML(message: userMessage,
                             openURL: channel.url),
                baseURL: nil)

        case .notYouTube:
            // Genuine non-YouTube web page (custom feed, network newsroom
            // live page, etc.) — load it directly.
            Log.ui.info("news_embed kind=\(channel.kind.rawValue, privacy: .public) channel=\(channel.name, privacy: .public) source=non_youtube iframe=false")
            if let url = URL(string: channel.url) {
                coordinator.lastFallbackOpenURL = nil
                web.load(URLRequest(url: url))
            } else {
                web.loadHTMLString(
                    placeholderHTML(message: "Channel URL is invalid:\n\(channel.url)"),
                    baseURL: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Called by SwiftUI when this view is removed from the hierarchy
    /// (news overlay closes, or "show news" flag turns the player off).
    /// Stopping JavaScript and loading a blank page releases the video
    /// pipeline immediately instead of leaving it running invisibly.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Stop JS / media playback synchronously.
        nsView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.pause();m.src='';m.load();});", completionHandler: nil)
        // Load a blank page to release the renderer process resources.
        nsView.load(URLRequest(url: URL(string: "about:blank")!))
        // Reset coordinator so that if the view is recreated for the same
        // channel it reloads rather than skipping due to signature match.
        coordinator.lastLoadedSignature = ""
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedSignature: String = ""
        var currentChannelName: String = ""
        var currentChannelId: String   = ""
        var currentRawURL: String = ""
        var lastEmbedURL: String? = nil
        /// The raw channel URL to offer in the "Open in browser" fallback.
        /// Nil when the embed succeeded.
        var lastFallbackOpenURL: String? = nil
        /// Same callback as `LiveNewsPlayerView.onLoadStatus`.  Set by
        /// `updateNSView` so the coordinator can publish state without
        /// holding a JarvisController reference.
        var onLoadStatus: ((_ channelId: String, _ status: String, _ error: String?) -> Void)? = nil

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            Log.ui.warning("news_embed_nav_failed channel=\(self.currentChannelName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            handleFailure(webView, error)
        }
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            Log.ui.warning("news_embed_provisional_failed channel=\(self.currentChannelName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            handleFailure(webView, error)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Detect the well-known YouTube interstitial domains — if we
            // ended up there, the embed pipeline failed and we should
            // surface the fallback UI rather than letting the user see a
            // sign-in / cookie page that looks broken.
            guard let host = webView.url?.host?.lowercased() else {
                // about:blank or data: HTML host page — the iframe inside
                // is what we actually care about.  Treat the parent-frame
                // load as "playing" because the iframe is now in the
                // document and YouTube's nocookie player takes it from here.
                if !currentChannelId.isEmpty {
                    onLoadStatus?(currentChannelId, "playing", nil)
                }
                return
            }
            let isCookieWall = host.hasPrefix("consent.")
            let isSignInWall = host == "accounts.google.com"
                            || host.hasSuffix(".accounts.google.com")
            if isCookieWall || isSignInWall {
                let what = isCookieWall ? "cookie_consent" : "sign_in"
                Log.ui.warning("""
                    news_embed_wall_detected channel=\(self.currentChannelName, privacy: .public) \
                    wall=\(what, privacy: .public) host=\(host, privacy: .public)
                    """)
                let msg = "YouTube tried to show its \(isCookieWall ? "cookie consent" : "sign-in") page.\n\nThe channel URL needs to be an embeddable video ID or embed URL."
                let openURL = currentRawURL
                webView.loadHTMLString(
                    LiveNewsPlayerView.fallbackHTML(message: msg, openURL: openURL),
                    baseURL: nil)
                if !currentChannelId.isEmpty {
                    onLoadStatus?(currentChannelId, "blocked", what)
                }
                return
            }
            // Normal embed-host load completed.
            if host.hasSuffix("youtube-nocookie.com") || host.hasSuffix("youtube.com") {
                if !currentChannelId.isEmpty {
                    onLoadStatus?(currentChannelId, "playing", nil)
                }
            }
        }

        /// Block any in-WKWebView navigation away from the embed host
        /// (clicking a YouTube logo, branded watermark, related video).
        /// Without this guard, a click inside the iframe can navigate the
        /// whole web view to the regular YouTube site — undoing the fix.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let host = target.host?.lowercased() ?? ""
            // Allow embed-host loads + local about: schemes.  Block anything
            // that would land us on the regular site.
            let isAllowed =
                host.isEmpty
                || host.hasSuffix("youtube-nocookie.com")
                || host == "youtube-nocookie.com"
                || target.scheme == "about"
                || (target.scheme == "data")
                || (navigationAction.navigationType == .other && host.hasSuffix("youtube-nocookie.com"))
            if !isAllowed {
                Log.ui.info("""
                    news_embed_blocked_nav channel=\(self.currentChannelName, privacy: .public) \
                    to_host=\(host, privacy: .public) nav_type=\(navigationAction.navigationType.rawValue, privacy: .public)
                    """)
                // If this is a top-frame click on a YouTube watch link,
                // re-route through our normalizer instead.
                if let httpURL = target.absoluteString
                    .removingPercentEncoding,
                   case .embed(let embedURL, _) = YouTubeURLNormalizer.normalize(httpURL) {
                    let html = LiveNewsPlayerView.youtubeIframeHTML(embedURL: embedURL)
                    webView.loadHTMLString(html,
                                           baseURL: URL(string: "https://www.youtube-nocookie.com/"))
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func handleFailure(_ web: WKWebView, _ error: Error) {
            if !currentChannelId.isEmpty {
                onLoadStatus?(currentChannelId, "failed", error.localizedDescription)
            }
            let msg = "Channel \(currentChannelName) failed to load.\n"
                    + "\(error.localizedDescription)\n\n"
                    + "If this is a YouTube channel, the channel may not be live "
                    + "right now, or its owner has disabled embedding."
            web.loadHTMLString(LiveNewsPlayerView.fallbackHTML(
                message: msg,
                openURL: lastFallbackOpenURL ?? currentRawURL),
                               baseURL: nil)
        }
    }

    // MARK: - HTML builders

    /// HTML host page for a YouTube embed URL.  The embed URL must
    /// already be on `youtube-nocookie.com/embed/…` form — see
    /// `YouTubeURLNormalizer`.  Loading this HTML via
    /// `WKWebView.loadHTMLString(_, baseURL: youtube-nocookie.com)` gives
    /// the iframe a same-origin parent so YouTube doesn't reject the
    /// player with error 153.
    static func youtubeIframeHTML(embedURL: String) -> String {
        // Autoplay must start muted to satisfy WKWebView's autoplay policy.
        // We then unmute via the YouTube IFrame Player API by posting two
        // JSON commands to the iframe's contentWindow once the player is
        // ready.  This is the canonical pattern documented by YouTube —
        // `enablejsapi=1` on the URL is what makes the postMessage route
        // accept commands.  We send two attempts (200 ms and 1500 ms after
        // load) because the player's "ready" state lands at different
        // times depending on connection speed.
        """
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            html,body{margin:0;padding:0;background:#000;
                      height:100%;width:100%;overflow:hidden}
            iframe{position:absolute;top:0;left:0;width:100%;height:100%;
                   border:0;background:#000}
          </style>
        </head>
        <body>
          <iframe id="jarvis-player"
            src="\(embedURL)"
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen
            referrerpolicy="origin">
          </iframe>
          <script>
            (function () {
              function unmute() {
                var f = document.getElementById('jarvis-player');
                if (!f || !f.contentWindow) return;
                try {
                  f.contentWindow.postMessage(
                    JSON.stringify({event:'command', func:'unMute', args:[]}),
                    'https://www.youtube-nocookie.com');
                  f.contentWindow.postMessage(
                    JSON.stringify({event:'command', func:'setVolume', args:[100]}),
                    'https://www.youtube-nocookie.com');
                  f.contentWindow.postMessage(
                    JSON.stringify({event:'command', func:'playVideo', args:[]}),
                    'https://www.youtube-nocookie.com');
                } catch (e) { /* swallow */ }
              }
              // Belt + braces — fire on iframe-load, then twice more
              // because the player's onReady can arrive after load.
              var f = document.getElementById('jarvis-player');
              if (f) { f.addEventListener('load', function () {
                setTimeout(unmute, 100);
                setTimeout(unmute, 600);
                setTimeout(unmute, 1500);
              }); }
              setTimeout(unmute, 1000);
              setTimeout(unmute, 2500);
            })();
          </script>
        </body>
        </html>
        """
    }

    /// Wrap a user-pasted `<iframe …>` snippet in a chrome-less host page.
    static func wrapIframeSnippet(_ snippet: String) -> String {
        """
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html,body{margin:0;padding:0;background:#000;
                      height:100%;width:100%;overflow:hidden}
            iframe{position:absolute;top:0;left:0;width:100%!important;
                   height:100%!important;border:0;background:#000}
          </style>
        </head>
        <body>
          \(snippet)
        </body>
        </html>
        """
    }

    /// Minimal HLS player. WKWebView's <video> element decodes HLS when
    /// the source URL is served with the right MIME type.
    static func hlsHTML(streamURL: String) -> String {
        """
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html,body{margin:0;background:#05080f;height:100%;}
            video{width:100%;height:100%;background:#000;}
          </style>
        </head>
        <body>
          <video src="\(streamURL)" autoplay controls playsinline></video>
        </body>
        </html>
        """
    }

    /// CSS + JS injected into every WKWebView page. When a YouTube
    /// `/@HANDLE/live` page loads, we hide every part of YouTube's
    /// chrome (masthead, sidebar, comments, etc.) and stretch the
    /// `<video>` element to fill the whole viewport so the overlay
    /// shows just the live broadcast. A MutationObserver re-applies
    /// the styles after YouTube's SPA navigation, so switching
    /// between channels keeps the zoomed-video look.
    fileprivate static let zoomVideoScript = """
    (function () {
      function applyZoom() {
        if (!/youtube\\.com/.test(location.hostname)) return;
        var css = `
          html, body {
            background: #000 !important;
            overflow: hidden !important;
            margin: 0 !important;
          }
          ytd-app, ytd-page-manager, ytd-watch-flexy,
          #content, #primary, #primary-inner, #player,
          #player-container, #ytd-player, ytd-player {
            background: #000 !important;
          }
          /* Hide everything that's not the player */
          ytd-masthead, #masthead-container, #related,
          #comments, #secondary, #secondary-inner,
          ytd-watch-metadata, ytd-watch-info-text,
          #info-contents, #meta, #below, #header, #chips,
          ytd-merch-shelf-renderer, .ytd-engagement-panel-section-list-renderer,
          ytd-popup-container, .ytp-chrome-top, .ytp-watermark,
          .ytp-pause-overlay, .ytp-ce-element, .ytp-cards-button,
          .ytp-cards-teaser, .ytp-suggested-action,
          ytd-watch-next-secondary-results-renderer {
            display: none !important;
          }
          /* Make the player fill the viewport */
          video, .html5-video-container, .html5-video-player,
          #movie_player, #player-container-outer, #player-theater-container,
          .ytd-watch-flexy[theater] #player-theater-container {
            width: 100vw !important;
            height: 100vh !important;
            max-width: 100vw !important;
            max-height: 100vh !important;
            top: 0 !important;
            left: 0 !important;
            position: fixed !important;
          }
          video {
            object-fit: contain !important;
            background: #000 !important;
            z-index: 9999 !important;
          }
        `;
        var existing = document.getElementById('__jarvis_zoom_css');
        if (existing) { existing.textContent = css; return; }
        var style = document.createElement('style');
        style.id = '__jarvis_zoom_css';
        style.textContent = css;
        document.head && document.head.appendChild(style);
      }
      applyZoom();
      // YouTube is a single-page app — re-apply when DOM mutates.
      var mo = new MutationObserver(function () { applyZoom(); });
      mo.observe(document.documentElement, { childList: true, subtree: true });
      // Also re-apply on history navigation.
      window.addEventListener('yt-navigate-finish', applyZoom, false);
      window.addEventListener('popstate', applyZoom, false);
    })();
    """

    /// Fallback page rendered when the embed can't be produced.  Shows
    /// the failure reason and an "Open in browser" link the user can
    /// click to launch the original URL in Safari.  The link uses the
    /// system browser, not the in-app WKWebView, so we never silently
    /// land on the YouTube sign-in page even on user gesture.
    static func fallbackHTML(message: String, openURL: String?) -> String {
        let safeMsg = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let safeURL = (openURL ?? "")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let button = openURL.map { _ in
            """
            <a class="btn" href="\(safeURL)" target="_blank" rel="noopener">Open in browser</a>
            """
        } ?? ""
        return """
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;background:#05080f;color:#cce8f8;
                    font:13px -apple-system,system-ui;height:100vh;width:100vw;
                    display:flex;align-items:center;justify-content:center;
                    text-align:center;padding:20px}
          .pad{padding:24px 28px;border:1px dashed rgba(255,120,120,0.45);
               border-radius:14px;background:rgba(30,8,8,0.45);
               max-width:560px;line-height:1.55}
          .pad b{display:block;color:#ff9e9e;margin-bottom:10px;
                 letter-spacing:1.5px;font-size:10px;text-transform:uppercase}
          .btn{display:inline-block;margin-top:14px;padding:8px 16px;
               background:#3b6fd1;color:#fff;border-radius:8px;
               text-decoration:none;font-weight:600;font-size:12px}
          .btn:hover{background:#5588e8}
        </style></head>
        <body><div class="pad"><b>Embedded playback unavailable</b>\(safeMsg)<br>\(button)</div></body></html>
        """
    }

    fileprivate static func placeholderHTML(message: String) -> String {
        """
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;background:transparent;
                    color:#9ec5d8;font:13px -apple-system,system-ui;
                    height:100vh;width:100vw;
                    display:flex;align-items:center;justify-content:center;
                    text-align:center;letter-spacing:0.5px;padding:20px}
          .pad{padding:24px 28px;border:1px dashed rgba(120,200,255,0.32);
               border-radius:14px;background:rgba(8,16,30,0.55);
               max-width:520px;line-height:1.5}
          .pad b{display:block;color:#cce8f8;margin-bottom:8px;
                 letter-spacing:1.5px;font-size:10px;text-transform:uppercase}
        </style></head>
        <body><div class="pad"><b>News</b>\(message.replacingOccurrences(of: "\n", with: "<br>"))</div></body></html>
        """
    }
}

/// Generic in-app web view for opening a single article URL inside the
/// `.article` overlay. Articles do NOT auto-play media — that's the only
/// real difference from `LiveNewsPlayerView`.
struct ArticleWebView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = .all  // never autoplay
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/17.0 Safari/605.1.15"
        // Opaque background — same reason as LiveNewsPlayerView.
        web.setValue(true, forKey: "drawsBackground")
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor(red: 0.05, green: 0.07,
                                             blue: 0.12, alpha: 1.0).cgColor
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard let url else {
            web.loadHTMLString(
                "<html><body style='background:transparent;color:#9ec5d8;font:13px -apple-system;display:flex;align-items:center;justify-content:center;height:100vh'><div>No article URL</div></body></html>",
                baseURL: nil)
            return
        }
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            web.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.pause();m.src='';m.load();});", completionHandler: nil)
        nsView.load(URLRequest(url: URL(string: "about:blank")!))
        coordinator.lastURL = nil
    }

    final class Coordinator { var lastURL: URL? }
}
