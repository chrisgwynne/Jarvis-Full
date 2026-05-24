import SwiftUI
import AppKit

/// Reddit overlay — same blueprint/HUD style as the other native
/// overlays.  Two-pane HSplitView: sources/post-list on the left, post
/// detail + comments on the right.
///
/// Drives the same `RedditStore` the voice intents do, so anything the
/// user does via voice ("show comments", "open the second one") and
/// anything they do here stays in sync.
struct RedditOverlayView: View {
    @Bindable var store: RedditStore
    let controller: JarvisController
    let state: AppState

    /// Which slice of `posts` to show in the list pane.  Top-level so
    /// AppState / JarvisController can drive it without importing UI.
    typealias Mode = RedditOverlayMode

    @State private var mode: Mode = .feed
    @State private var selectedPostId: String? = nil
    @State private var showComments: Bool = false
    @State private var isLoadingComments: Bool = false
    @State private var commentSummary: String? = nil
    @State private var postSummary: String? = nil
    @State private var isSummarising: Bool = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

            postList
                .frame(minWidth: 280, idealWidth: 360)

            detailPane
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedPostId == nil {
                selectedPostId = currentList.first?.id
            }
        }
        .onChange(of: state.redditPendingSelectionPostId) { _, id in
            if let id, !id.isEmpty {
                selectedPostId = id
                state.redditPendingSelectionPostId = nil
                if state.redditAutoOpenComments {
                    state.redditAutoOpenComments = false
                    Task { await loadComments(for: id) }
                }
            }
        }
        .onChange(of: state.redditPendingMode) { _, m in
            if let m {
                mode = m
                selectedPostId = currentList.first?.id
                state.redditPendingMode = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Views") {
                    sourceRow("All — recent",
                              symbol: "newspaper",
                              selected: mode == .feed) {
                        mode = .feed
                        selectedPostId = currentList.first?.id
                    }
                    sourceRow("All — top",
                              symbol: "flame",
                              selected: mode == .top) {
                        mode = .top
                        selectedPostId = currentList.first?.id
                    }
                    if case .search(let q) = mode {
                        sourceRow("Search: \"\(q)\"",
                                  symbol: "magnifyingglass",
                                  selected: true) { /* no-op */ }
                    }
                }
                Section("Subreddits") {
                    ForEach(store.sources) { s in
                        sourceRow("r/\(s.subreddit)",
                                  symbol: "circle.fill",
                                  selected: mode == .subreddit(s.id),
                                  disabled: !s.enabled) {
                            mode = .subreddit(s.id)
                            selectedPostId = currentList.first?.id
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    Task { await store.refreshAllEnabledSources() }
                } label: {
                    Label(store.isRefreshing ? "Refreshing…" : "Refresh",
                          systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .disabled(store.isRefreshing)
                Spacer()
                if let date = store.lastFullRefreshAt {
                    Text(relativeAge(date))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private func sourceRow(_ label: String,
                           symbol: String,
                           selected: Bool,
                           disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? .orange : .secondary.opacity(disabled ? 0.3 : 0.7))
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(disabled ? .secondary : .primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Post list

    private var currentList: [RedditPost] {
        switch mode {
        case .feed:
            return store.posts
                .filter { !store.dismissedPostIds.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
        case .top:
            return store.topPostsAcrossSources
        case .subreddit(let id):
            return store.posts(forSourceId: id)
                .sorted { $0.createdAt > $1.createdAt }
        case .search:
            // Search results are merged into store.posts; show all
            // (newest first) — the search query is shown in the sidebar.
            return store.posts
                .filter { !store.dismissedPostIds.contains($0.id) }
                .sorted { $0.score > $1.score }
        }
    }

    private var postList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(listTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(currentList.count) posts")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(currentList) { post in
                        postRow(post)
                            .onTapGesture {
                                selectedPostId = post.id
                                store.markSeen(post)
                                commentSummary = nil
                                postSummary    = nil
                                pushActiveContext(post)
                            }
                        Divider()
                    }
                    if currentList.isEmpty {
                        emptyState
                    }
                }
            }
        }
    }

    private var listTitle: String {
        switch mode {
        case .feed:               return "Latest"
        case .top:                return "Top"
        case .subreddit(let id):  return store.source(id: id).map { "r/\($0.subreddit)" } ?? "Subreddit"
        case .search(let q):      return "Search: \(q)"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No posts cached. Try Refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func postRow(_ post: RedditPost) -> some View {
        let isSelected = post.id == selectedPostId
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                Text(formatScore(post.score))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(post.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text("r/\(post.subreddit)")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.85))
                    Text("u/\(post.author)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("• \(post.commentsCount) comments")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(relativeAge(post.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                if let flair = post.flair, !flair.isEmpty {
                    Text(flair)
                        .font(.system(size: 8))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.orange.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        Group {
            if let id = selectedPostId,
               let post = currentList.first(where: { $0.id == id })
                       ?? store.posts.first(where: { $0.id == id })
            {
                postDetail(post)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Select a post to see details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func postDetail(_ post: RedditPost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(post.title)
                    .font(.system(size: 16, weight: .semibold))
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Label("\(formatScore(post.score)) score",
                          systemImage: "arrow.up")
                    Label("\(post.commentsCount) comments",
                          systemImage: "text.bubble")
                    Label("r/\(post.subreddit)", systemImage: "person.3")
                    Label("u/\(post.author)", systemImage: "person")
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        Task { await loadComments(for: post.id) }
                    } label: {
                        Label(showComments ? "Reload Comments" : "Show Comments",
                              systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isLoadingComments)

                    Button {
                        if let url = URL(string: post.url) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.toggleSaved(post)
                    } label: {
                        Label(store.savedPostIds.contains(post.id)
                              ? "Unsave" : "Save",
                              systemImage: store.savedPostIds.contains(post.id)
                              ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await summarisePostBody(post) }
                    } label: {
                        Label("Summarise Post", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(post.selfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button {
                        store.dismiss(post)
                        selectedPostId = currentList.first?.id
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))

                if isSummarising {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Summarising…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let s = postSummary {
                    summaryCard("Post summary", text: s)
                }

                if !post.selfText.isEmpty {
                    Text(post.selfText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if showComments {
                    commentsSection(for: post)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func summaryCard(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func commentsSection(for post: RedditPost) -> some View {
        let comments = store.commentsByPostId[post.id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comments")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    Task { await summariseCommentsForPost(post) }
                } label: {
                    Label("Summarise Comments", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(comments.isEmpty || isSummarising)
            }

            if let s = commentSummary {
                summaryCard("Comment summary", text: s)
            }

            if isLoadingComments {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading comments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if comments.isEmpty {
                Text("No comments cached. Tap Reload Comments above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comments) { c in
                    commentRow(c)
                }
            }
        }
    }

    private func commentRow(_ c: RedditComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("u/\(c.author)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.85))
                Text("\(c.score) points")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(relativeAge(c.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            Text(c.body)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(c.depth) * 12)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func loadComments(for postId: String) async {
        guard let post = store.posts.first(where: { $0.id == postId }) else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        _ = await store.loadComments(for: post)
        showComments = true
    }

    private func summarisePostBody(_ post: RedditPost) async {
        let body = post.selfText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            postSummary = "(no body text on this post — only an outbound link)"
            return
        }
        isSummarising = true
        defer { isSummarising = false }
        if let s = await controller.summariseRedditText(
            title: post.title, body: body, kind: .post) {
            postSummary = s
        } else {
            postSummary = "Summary unavailable — LLM disabled or unreachable."
        }
    }

    private func summariseCommentsForPost(_ post: RedditPost) async {
        var comments = store.commentsByPostId[post.id] ?? []
        if comments.isEmpty {
            _ = await store.loadComments(for: post)
            comments = store.commentsByPostId[post.id] ?? []
        }
        guard !comments.isEmpty else {
            commentSummary = "No comments to summarise."
            return
        }
        isSummarising = true
        defer { isSummarising = false }
        let joined = comments.prefix(40).map {
            "[\($0.score)] u/\($0.author): \($0.body)"
        }.joined(separator: "\n")
        if let s = await controller.summariseRedditText(
            title: "Comments on: \(post.title)", body: joined, kind: .comments) {
            commentSummary = s
        } else {
            commentSummary = "Summary unavailable — LLM disabled or unreachable."
        }
    }

    private func pushActiveContext(_ post: RedditPost) {
        ActiveContextRegistry.shared.record(
            source: .other,
            title: "Reddit: " + post.title,
            summary: "r/\(post.subreddit) — \(post.commentsCount) comments, \(formatScore(post.score)) points",
            externalIdentifier: post.id,
            openableURL: "https://www.reddit.com" + post.permalink,
            pronouns: ["it", "that", "this", "post", "this post", "that post"],
            priority: 5,
            suggestedActions: [.open, .summarise, .describeMore])
    }

    private func formatScore(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        if n >= 1_000  { return String(format: "%.1fk", Double(n) / 1000) }
        return String(n)
    }

    private func relativeAge(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60       { return "now" }
        if s < 3600     { return "\(Int(s/60))m" }
        if s < 86_400   { return "\(Int(s/3600))h" }
        return "\(Int(s/86_400))d"
    }
}
