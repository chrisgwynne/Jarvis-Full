import Foundation

/// Orchestrates periodic feed refreshes and watch-mode monitoring.
/// Spawns background async tasks; all state mutations on @MainActor.
@Observable
@MainActor
final class NewsRefreshScheduler {

    // MARK: - Observable state

    private(set) var isRefreshing: Bool = false
    private(set) var activeRefreshFeedName: String = ""
    private(set) var lastResults: [FeedRefreshResult] = []
    private(set) var watchConfigs: [FeedWatchConfig] = []

    // Callback invoked on the main actor after any refresh with new-article count.
    var onNewArticles: ((Int, String) -> Void)?

    /// Callback invoked with the actual new articles for proactivity signal generation.
    var onNewArticlesForProactivity: (([NewsArticle]) -> Void)?

    // MARK: - Private

    private let store: NewsStore
    private var timerTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// Set to `false` after the very first `refreshAll()` completes.
    ///
    /// On the first poll the DB is cold: every article from every feed is
    /// "new" in the SQLite sense.  Without this guard, a fresh install (or a
    /// clean DB wipe) floods the proactivity engine with hundreds of signals
    /// at launch.  The first poll seeds the DB silently; only subsequent
    /// refreshes emit proactivity callbacks.
    private var isFirstPoll = true

    // MARK: - Init / Lifecycle

    init(store: NewsStore) {
        self.store = store
    }

    func start() {
        startRefreshTimer()
        startWatchTimer()
    }

    func stop() {
        timerTask?.cancel()
        watchTask?.cancel()
        timerTask = nil
        watchTask = nil
    }

    // MARK: - Manual refresh

    /// Refresh all enabled feeds. Returns total new article count.
    @discardableResult
    func refreshAll() async -> Int {
        let feeds = store.feeds.filter { $0.enabled }
        guard !feeds.isEmpty else { return 0 }
        isRefreshing = true
        var totalNew = 0
        var results: [FeedRefreshResult] = []

        // Capture before any async work so all feeds in this batch
        // see the same seeding flag.
        let seedingThisPoll = isFirstPoll

        for feed in feeds {
            let result = await refreshFeed(feed, seedingPoll: seedingThisPoll)
            results.append(result)
            totalNew += result.newArticleCount
        }

        // Mark first poll complete only after all feeds finish,
        // so a partial refresh (e.g. after a crash mid-loop) still
        // seeds silently on the next launch.
        if seedingThisPoll { isFirstPoll = false }

        lastResults = results
        isRefreshing = false
        activeRefreshFeedName = ""
        store.loadRecentArticles()

        if totalNew > 0 {
            let sources = results.filter { $0.newArticleCount > 0 }
                .map(\.feedName).prefix(3).joined(separator: ", ")
            onNewArticles?(totalNew, sources)
        }

        return totalNew
    }

    /// Refresh a single named feed (by partial name match).
    @discardableResult
    func refreshFeedNamed(_ name: String) async -> FeedRefreshResult? {
        let lower = name.lowercased()
        guard let feed = store.feeds.first(where: { $0.name.lowercased().contains(lower) }) else {
            return nil
        }
        // A user-triggered single-feed refresh implies the app is running;
        // clear the first-poll gate so proactivity signals flow normally.
        isFirstPoll = false
        isRefreshing = true
        let result = await refreshFeed(feed)
        isRefreshing = false
        activeRefreshFeedName = ""
        if result.newArticleCount > 0 { store.loadRecentArticles() }
        return result
    }

    // MARK: - Watch mode

    func addWatch(feedID: String, labelFilter: NewsLabel? = nil) {
        guard !watchConfigs.contains(where: { $0.feedID == feedID }) else { return }
        watchConfigs.append(FeedWatchConfig(feedID: feedID, labelFilter: labelFilter))
    }

    func removeWatch(feedID: String) {
        watchConfigs.removeAll { $0.feedID == feedID }
    }

    func removeAllWatches() {
        watchConfigs.removeAll()
    }

    var isWatching: Bool { !watchConfigs.isEmpty }

    func watchedFeedNames() -> [String] {
        watchConfigs.compactMap { config in
            store.feeds.first { $0.id == config.feedID }?.name
        }
    }

    // MARK: - Private: single feed refresh

    /// - Parameter seedingPoll: When `true` the feed is fetched and inserted
    ///   into the DB normally, but the `onNewArticlesForProactivity` callback
    ///   is suppressed.  This prevents a cold-DB first launch from flooding
    ///   the proactivity engine with every article ever published.
    private func refreshFeed(_ feed: NewsFeed, seedingPoll: Bool = false) async -> FeedRefreshResult {
        activeRefreshFeedName = feed.name
        let start = Date()
        do {
            let parsed = try await RSSFetcher.fetch(feed: feed)
            let feedHints = NewsSourceRegistry.feedLabelHints[feed.id] ?? []
            var articles: [NewsArticle] = []

            for item in parsed {
                let labels = NewsLabeller.label(
                    title: item.title,
                    description: item.description,
                    feedHints: feedHints
                )
                let excerpt = String(item.description.prefix(300))
                let score = NewsLabeller.importanceScore(labels: labels, title: item.title)
                let article = NewsArticle(
                    feedID: feed.id,
                    sourceName: feed.name,
                    title: item.title,
                    url: item.link,
                    publishedAt: item.pubDate ?? Date(),
                    fetchedAt: Date(),
                    summary: NewsSummariser.briefSummary(article: NewsArticle(
                        feedID: feed.id, sourceName: feed.name, title: item.title,
                        url: item.link, contentExcerpt: excerpt, labels: labels
                    )),
                    contentExcerpt: excerpt,
                    labels: labels,
                    importanceScore: score
                )
                articles.append(article)
            }

            let inserted = await store.insertArticles(articles)
            store.recordRefresh(feedID: feed.id)

            // Notify proactivity engine of newly inserted articles only.
            // Skip on the first-ever poll so a cold DB doesn't flood the
            // engine with hundreds of articles at launch.
            if !seedingPoll, inserted > 0, let cb = onNewArticlesForProactivity {
                // Only forward articles with notable importance to avoid noise.
                let notable = articles.filter { $0.importanceScore >= 0.5 }
                if !notable.isEmpty { cb(notable) }
            }

            return FeedRefreshResult(
                feedID: feed.id,
                feedName: feed.name,
                newArticleCount: inserted,
                totalFetched: parsed.count,
                error: nil,
                duration: -start.timeIntervalSinceNow
            )
        } catch {
            return FeedRefreshResult(
                feedID: feed.id,
                feedName: feed.name,
                newArticleCount: 0,
                totalFetched: 0,
                error: error.localizedDescription,
                duration: -start.timeIntervalSinceNow
            )
        }
    }

    // MARK: - Timers

    private func startRefreshTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            // Initial refresh after 5s on startup
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshAll()

            // Then every 30 minutes — respect per-feed intervals by refreshing all
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshAll()
            }
        }
    }

    private func startWatchTimer() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 min tick
                guard let self, !Task.isCancelled else { return }
                await self.checkWatchedFeeds()
            }
        }
    }

    private func checkWatchedFeeds() async {
        for i in watchConfigs.indices {
            let config = watchConfigs[i]
            guard let feed = store.feeds.first(where: { $0.id == config.feedID }) else { continue }
            let result = await refreshFeed(feed)
            if result.newArticleCount > 0 {
                let label = watchConfigs[i].labelFilter?.displayName
                let desc = label != nil ? "\(result.newArticleCount) new \(label!) stories from \(feed.name)"
                                       : "\(result.newArticleCount) new stories from \(feed.name)"
                onNewArticles?(result.newArticleCount, desc)
                watchConfigs[i].lastChecked = Date()
            }
        }
        if watchConfigs.contains(where: { _ in true }) {
            store.loadRecentArticles()
        }
    }
}
