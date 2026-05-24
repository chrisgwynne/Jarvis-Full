import Foundation
import Observation

/// A user-configurable live news / video source surfaced inside the
/// News overlay. Each channel resolves to a URL the embedded WebKit
/// player can load. The store persists to JSON under Application
/// Support so it survives relaunch and can be edited externally.
struct NewsChannel: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Generic web page — only used for explicitly non-YouTube sources
        /// (e.g. `bbc.co.uk/news/live`).  YouTube URLs in any kind are
        /// re-routed through the YouTube normalizer at load time so the
        /// "watch news" command never lands on a YouTube sign-in / cookie
        /// page even when the channel was misconfigured.
        case webPage
        /// YouTube watch / embed / live URL — `LiveNewsPlayerView` parses
        /// the URL via `YouTubeURLNormalizer`, builds an iframe wrapper on
        /// `youtube-nocookie.com`, and loads that.
        case youtubeEmbed
        /// User pasted a full `<iframe …>` HTML snippet.  Loaded as a raw
        /// HTML wrapper.
        case iframeEmbed
        /// HLS `.m3u8` — loaded directly via a `<video>` tag.
        case hls
        case custom

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .webPage:      return "Web page"
            case .youtubeEmbed: return "YouTube embed"
            case .iframeEmbed:  return "iframe snippet"
            case .hls:          return "HLS stream"
            case .custom:       return "Custom"
            }
        }
    }

    let id: String
    var name: String
    var url: String
    var kind: Kind = .webPage
    var isDefault: Bool = false
    var enabled: Bool = true
}

@Observable
@MainActor
final class NewsChannelStore {
    private(set) var channels: [NewsChannel] = []
    var activeChannelID: String? = nil

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        fileURL = dir.appendingPathComponent("news_channels.json")
        load()
        if channels.isEmpty {
            seedDefaults()
            save()
        }
        // One-time migration: an earlier build seeded YouTube
        // `youtube.com/@HANDLE/live` URLs with `kind: .webPage`, which
        // loaded the real YouTube channel page and triggered the cookie
        // banner / sign-in wall on every "watch news" call.  Wipe and
        // re-seed any channel that still carries that pattern so
        // existing users automatically migrate to the iframe-embed flow.
        let needsReseed = channels.contains { ch in
            ch.url.contains("/@") && ch.url.contains("/live")
                && ch.kind == .webPage
        }
        if needsReseed {
            channels = []
            activeChannelID = nil
            seedDefaults()
            save()
        }

        // Additive migration: if the ABC News default isn't present (added
        // in the live-news / watch-mode sprint) and no user channel of
        // the same id exists, append it.  Preserves any custom edits.
        if !channels.contains(where: { $0.id == "abc_news_live" }) {
            channels.append(NewsChannel(
                id: "abc_news_live",
                name: "ABC News",
                url: "https://www.youtube.com/embed/live_stream?channel=UCBi2mrWuNuyYy4gbM6fU18Q",
                kind: .youtubeEmbed))
            save()
        }
        if activeChannelID == nil
            || channels.first(where: { $0.id == activeChannelID }) == nil {
            activeChannelID = defaultChannel?.id ?? channels.first?.id
        }
    }

    // MARK: - Lookup

    var enabledChannels: [NewsChannel] { channels.filter { $0.enabled } }

    var activeChannel: NewsChannel? {
        guard let id = activeChannelID else { return defaultChannel }
        return channels.first(where: { $0.id == id }) ?? defaultChannel
    }

    var defaultChannel: NewsChannel? {
        channels.first(where: { $0.isDefault && $0.enabled })
            ?? enabledChannels.first
    }

    /// Best-effort match by display name (case-insensitive). Prefers
    /// exact match, then prefix match, then contains.
    func channel(matchingName q: String) -> NewsChannel? {
        let lower = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }
        if let exact = enabledChannels.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        if let pre = enabledChannels.first(where: { $0.name.lowercased().hasPrefix(lower) }) {
            return pre
        }
        return enabledChannels.first(where: { $0.name.lowercased().contains(lower) })
    }

    // MARK: - Mutation

    @discardableResult
    func setActive(byNameContaining q: String) -> NewsChannel? {
        guard let ch = channel(matchingName: q) else { return nil }
        activeChannelID = ch.id
        save()
        return ch
    }

    func setActive(id: String) {
        guard channels.contains(where: { $0.id == id && $0.enabled }) else { return }
        activeChannelID = id
        save()
    }

    @discardableResult
    func cycleNext() -> NewsChannel? {
        let list = enabledChannels
        guard !list.isEmpty else { return nil }
        let i = list.firstIndex(where: { $0.id == activeChannelID }) ?? -1
        let next = list[(i + 1) % list.count]
        activeChannelID = next.id
        save()
        return next
    }

    @discardableResult
    func cyclePrev() -> NewsChannel? {
        let list = enabledChannels
        guard !list.isEmpty else { return nil }
        let i = list.firstIndex(where: { $0.id == activeChannelID }) ?? 0
        let prev = list[(i - 1 + list.count) % list.count]
        activeChannelID = prev.id
        save()
        return prev
    }

    func add(_ ch: NewsChannel) {
        channels.append(ch)
        save()
    }

    func update(_ ch: NewsChannel) {
        if let i = channels.firstIndex(where: { $0.id == ch.id }) {
            channels[i] = ch
            save()
        }
    }

    func remove(id: String) {
        channels.removeAll { $0.id == id }
        if activeChannelID == id { activeChannelID = defaultChannel?.id }
        save()
    }

    /// Wipe persisted channel list and re-seed defaults. Useful when a
    /// previously-saved channel URL has gone stale (e.g. YouTube
    /// rejecting an old embed) — the user can recover without editing
    /// JSON by hand. Exposed for a future Settings → News button.
    func resetToDefaults() {
        channels = []
        activeChannelID = nil
        seedDefaults()
        activeChannelID = defaultChannel?.id
        save()
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var channels: [NewsChannel]
        var activeChannelID: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(StoreFile.self, from: data) {
            channels = decoded.channels
            activeChannelID = decoded.activeChannelID
        }
    }

    private func save() {
        let f = StoreFile(channels: channels, activeChannelID: activeChannelID)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Editable defaults.
    ///
    /// All YouTube defaults use the documented
    /// `youtube.com/embed/live_stream?channel=CHANNEL_ID` shape — the only
    /// YouTube URL pattern that produces a clean iframe-embedded live
    /// player without the sign-in / cookie-consent wall.
    /// `LiveNewsPlayerView` then re-normalizes through
    /// `YouTubeURLNormalizer` to the privacy-enhanced
    /// `youtube-nocookie.com` host and wraps the result in an iframe.
    ///
    /// Channel IDs below are publicly-known stable identifiers.  If any
    /// specific channel rejects embedding on a given install, the
    /// runtime fallback UI (`LiveNewsPlayerView` placeholder) surfaces a
    /// clear error and the user can edit the URL in Settings → News.
    private func seedDefaults() {
        channels = [
            NewsChannel(
                id: "bbc_news_live",
                name: "BBC News",
                url: "https://www.youtube.com/embed/live_stream?channel=UC16niRr50-MSBwiO3YDb3RA",
                kind: .youtubeEmbed,
                isDefault: true,
                enabled: true
            ),
            NewsChannel(
                id: "sky_news_live",
                name: "Sky News",
                url: "https://www.youtube.com/embed/live_stream?channel=UCoMdktPbSTixAyNGwb-UYkQ",
                kind: .youtubeEmbed
            ),
            NewsChannel(
                id: "bloomberg_live",
                name: "Bloomberg",
                url: "https://www.youtube.com/embed/live_stream?channel=UCIALMKvObZNtJ6AmdCLP7Lg",
                kind: .youtubeEmbed
            ),
            NewsChannel(
                id: "dw_news_live",
                name: "DW News",
                url: "https://www.youtube.com/embed/live_stream?channel=UCknLrEdhRCp1aegoMqRaCZg",
                kind: .youtubeEmbed
            ),
            NewsChannel(
                id: "aljazeera_live",
                name: "Al Jazeera",
                url: "https://www.youtube.com/embed/live_stream?channel=UCNye-wNBqNL5ZzHSJj3l8Bg",
                kind: .youtubeEmbed
            ),
            // ABC News Live (US).  Channel id is the canonical public id;
            // if ABC ever disables embedding the watch overlay surfaces
            // the "blocked" badge and offers Open-in-browser.
            NewsChannel(
                id: "abc_news_live",
                name: "ABC News",
                url: "https://www.youtube.com/embed/live_stream?channel=UCBi2mrWuNuyYy4gbM6fU18Q",
                kind: .youtubeEmbed
            ),
        ]
    }
}
