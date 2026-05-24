import SwiftUI

/// News overlay — blueprint-style layout with:
///   * top: live channel player (WKWebView)
///   * middle: channel selector chips
///   * bottom: scrollable headline list (clickable)
///
/// Clicking a headline routes through the JarvisController so the
/// behaviour stays consistent with voice ("open story one") and the
/// in-app article overlay can be reused.
struct NewsOverlayView: View {
    let store: NewsStore
    let scheduler: NewsRefreshScheduler
    let channelStore: NewsChannelStore
    let controller: JarvisController
    let state: AppState

    @State private var searchText: String = ""
    @State private var selectedLabel: NewsLabel? = nil
    @State private var showSaved: Bool = false
    @State private var searchResults: [NewsArticle] = []

    private var displayArticles: [NewsArticle] {
        if !searchText.isEmpty { return searchResults }
        let base = showSaved ? store.savedArticles : store.articles
        if let label = selectedLabel {
            return base.filter { $0.labels.contains(label) }
        }
        return base
    }

    var body: some View {
        // Two layouts driven by `state.newsOverlayMode`.
        // `.watch` shows ONLY the player + channel selector — no headline
        // feed underneath.  `.headlines` is the previous layout (kept for
        // "show news" / "summarise news" / clicking a headline-feed open).
        Group {
            switch state.newsOverlayMode {
            case .watch:     watchLayout
            case .headlines: headlinesLayout
            }
        }
        .background(Color.clear)
        // Headline list refresh only fires for the headlines layout — no
        // point churning the feed query when the user is watching live TV.
        .task(id: state.newsOverlayMode) {
            if state.newsOverlayMode == .headlines {
                store.loadRecentArticles(limit: 80)
                store.loadSavedArticles()
            }
        }
    }

    // MARK: - Layouts

    /// Headlines: live-player placeholder (or full player on "watch"
    /// inside this mode — defensively kept), channel strip, search,
    /// label chips, article list.
    private var headlinesLayout: some View {
        VStack(spacing: 0) {
            livePlayerArea
            channelStrip
            Divider().overlay(Color.cyan.opacity(0.18))
            searchAndFilter
            Divider().overlay(Color.cyan.opacity(0.10))
            if displayArticles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
    }

    /// Watch: full-bleed player + channel selector + close.  Nothing else.
    private var watchLayout: some View {
        VStack(spacing: 0) {
            // Live player fills the available space.
            ZStack(alignment: .topLeading) {
                LiveNewsPlayerView(
                    channel: channelStore.activeChannel,
                    onLoadStatus: { id, status, err in
                        controller.recordNewsChannelLoadStatus(
                            channelId: id, status: status, error: err)
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let ch = channelStore.activeChannel {
                    HStack(spacing: 6) {
                        Label(ch.name, systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(.cyan)
                        loadStatusBadge(for: ch.id)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.25)))
                    .padding(12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Channel selector strip — with per-channel status badges.
            channelStripWithStatus
        }
    }

    // MARK: - Live player

    private var livePlayerArea: some View {
        Group {
            if state.newsLivePlayerVisible {
                // "watch news" — full WKWebView live stream.
                ZStack(alignment: .topLeading) {
                    LiveNewsPlayerView(
                        channel: channelStore.activeChannel,
                        onLoadStatus: { id, status, err in
                            controller.recordNewsChannelLoadStatus(
                                channelId: id, status: status, error: err)
                        })
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let ch = channelStore.activeChannel {
                        Label(ch.name, systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.25)))
                            .padding(10)
                    }
                }
                .frame(height: 240)
            } else {
                // "show news" — lightweight placeholder; no WKWebView loaded.
                watchLivePlaceholder
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// Shown in place of the WKWebView when only text headlines were requested.
    /// Tapping (or saying "watch news") activates the live stream.
    private var watchLivePlaceholder: some View {
        Button {
            // Activating via button mirrors what "watch news" voice command does.
            state.newsLivePlayerVisible = true
            if let ch = channelStore.activeChannel {
                controller.onNewsChannelChanged(ch)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.15), lineWidth: 1)
                    )
                VStack(spacing: 8) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 26))
                        .foregroundStyle(.cyan.opacity(0.55))
                    Text("Watch Live")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.cyan.opacity(0.70))
                    Text("Say 'watch news' or tap to load live stream")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: 240)
    }

    // MARK: - Channel selector

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(channelStore.enabledChannels) { ch in
                    Button {
                        channelStore.setActive(id: ch.id)
                        controller.onNewsChannelChanged(ch)
                    } label: {
                        Text(ch.name)
                            .font(.system(size: 11, weight: .medium,
                                          design: .monospaced))
                            .tracking(0.6)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    ch.id == channelStore.activeChannelID
                                    ? Color.cyan.opacity(0.22)
                                    : Color.white.opacity(0.05)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    ch.id == channelStore.activeChannelID
                                    ? Color.cyan.opacity(0.55)
                                    : Color.white.opacity(0.10)
                                )
                            )
                            .foregroundStyle(
                                ch.id == channelStore.activeChannelID
                                ? Color.cyan : Color.secondary
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Channel selector with a small status badge per channel (loading /
    /// blocked / failed / playing).  Used by the watch layout.  No
    /// headline feed underneath.
    private var channelStripWithStatus: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(channelStore.enabledChannels) { ch in
                    Button {
                        channelStore.setActive(id: ch.id)
                        controller.onNewsChannelChanged(ch)
                        // Voice path also re-enters media playback; the
                        // click path does too so the listening-pause rule
                        // applies whether the user clicked or spoke.
                        controller.enterMediaPlayback(channel: ch.name)
                    } label: {
                        HStack(spacing: 5) {
                            Text(ch.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.6)
                            loadStatusBadge(for: ch.id)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                ch.id == channelStore.activeChannelID
                                ? Color.cyan.opacity(0.22)
                                : Color.white.opacity(0.05)
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                ch.id == channelStore.activeChannelID
                                ? Color.cyan.opacity(0.55)
                                : Color.white.opacity(0.10)
                            )
                        )
                        .foregroundStyle(
                            ch.id == channelStore.activeChannelID
                            ? Color.cyan : Color.secondary
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Tiny coloured dot + label for the per-channel load state.  Hidden
    /// for `.loading` initial state to avoid flicker; surfaces the
    /// problem clearly when a channel is `.blocked` / `.failed`.
    @ViewBuilder
    private func loadStatusBadge(for channelId: String) -> some View {
        let s = state.newsChannelLoadStatus[channelId] ?? ""
        switch s {
        case "blocked":
            Label("blocked", systemImage: "nosign")
                .labelStyle(.iconOnly)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(state.newsChannelLastError[channelId]
                      ?? "This channel does not allow embedded playback.")
        case "failed":
            Label("failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .help(state.newsChannelLastError[channelId] ?? "Failed to load.")
        case "playing":
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 8))
                .foregroundStyle(.green)
        case "loading":
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    // MARK: - Search + label filter

    private var searchAndFilter: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Search headlines…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: searchText) { _, q in performSearch(q) }
                if !searchText.isEmpty {
                    Button { searchText = ""; searchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await scheduler.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(scheduler.isRefreshing)
                .help("Refresh feeds")

                Toggle(isOn: $showSaved) {
                    Image(systemName: showSaved ? "bookmark.fill" : "bookmark")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(showSaved ? .yellow : .secondary)
                .help("Saved articles")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(white: 1.0, opacity: 0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip(nil, label: "All")
                    ForEach(NewsLabel.allCases) { l in
                        chip(l, label: l.displayName)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func chip(_ value: NewsLabel?, label displayName: String) -> some View {
        let selected = selectedLabel == value
        Button {
            withAnimation(.spring(duration: 0.2)) { selectedLabel = value }
        } label: {
            Text(displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? .black : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(selected
                                           ? Color.cyan
                                           : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Article list

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayArticles.enumerated()), id: \.element.id) { idx, article in
                    ArticleRow(
                        index: idx + 1,
                        article: article,
                        onOpen: {
                            controller.openArticle(article)
                        },
                        onSave: {
                            store.toggleSaved(article: article)
                        }
                    )
                    Divider().opacity(0.10).padding(.leading, 14)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 32))
                .foregroundStyle(.cyan.opacity(0.45))
            Text(searchText.isEmpty
                 ? "No headlines loaded yet."
                 : "No results for \"\(searchText)\"")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if searchText.isEmpty {
                Text("Add feeds in Settings → News, or say 'watch news' for live stream.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []; return
        }
        Task { searchResults = await store.searchArticles(query: query) }
    }
}

// MARK: - ArticleRow

private struct ArticleRow: View {
    let index: Int
    let article: NewsArticle
    let onOpen: () -> Void
    let onSave: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.55))
                    .frame(width: 22, alignment: .trailing)
                    .padding(.top, 2)

                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .font(.system(size: 12,
                                      weight: article.isRead ? .regular : .semibold))
                        .foregroundStyle(article.isRead
                                         ? Color.secondary
                                         : Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        Text(article.sourceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))
                            .font(.caption2)
                        Text(timeAgo)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !article.labels.isEmpty {
                            ForEach(article.labels.prefix(2), id: \.self) { l in
                                Text(l.displayName)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.07)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Save button — separate Button so it doesn't trigger row open.
                Button(action: onSave) {
                    Image(systemName: article.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.caption)
                        .foregroundStyle(article.isSaved ? .yellow : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(hovered || article.isSaved ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(hovered ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var accentColor: Color {
        guard let first = article.labels.first else { return .gray.opacity(0.35) }
        return Color(hex: first.accentHex).opacity(0.75)
    }

    private var timeAgo: String {
        let s = -article.publishedAt.timeIntervalSinceNow
        if s < 3600  { return "\(Int(s/60))m ago" }
        if s < 86400 { return "\(Int(s/3600))h ago" }
        return "\(Int(s/86400))d ago"
    }
}

// MARK: - Color(hex:) — scoped

private extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(h, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
