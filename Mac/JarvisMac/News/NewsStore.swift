import Foundation

/// Service layer wrapping JarvisDatabase for all news operations.
/// All mutating calls are dispatched to `queue` (serial background queue);
/// read calls that need freshness also go through the queue.
/// Published updates to `feeds` and `articles` are pushed to @MainActor consumers.
@Observable
@MainActor
final class NewsStore {

    // MARK: - Published state

    private(set) var feeds: [NewsFeed] = []
    private(set) var articles: [NewsArticle] = []
    private(set) var savedArticles: [NewsArticle] = []
    private(set) var lastRefreshDates: [String: Date] = [:]  // feedID → last successful refresh
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    // MARK: - Private

    private let db: JarvisDatabase
    private let queue = DispatchQueue(label: "com.jarvis.newsstore", qos: .utility)

    // MARK: - Init

    init(db: JarvisDatabase) {
        self.db = db
    }

    // MARK: - Feeds

    func loadFeeds() {
        queue.async { [weak self] in
            guard let self else { return }
            let result = (try? self.db.allNewsFeeds()) ?? []
            DispatchQueue.main.async { self.feeds = result }
        }
    }

    /// Seed default feeds on first launch (only inserts if table is empty).
    func seedDefaultFeedsIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let existing = try? self.db.allNewsFeeds(), existing.isEmpty else { return }
            for feed in NewsSourceRegistry.defaultFeeds {
                try? self.db.upsertNewsFeed(feed)
            }
            let seeded = (try? self.db.allNewsFeeds()) ?? []
            DispatchQueue.main.async { self.feeds = seeded }
        }
    }

    func saveFeed(_ feed: NewsFeed, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.db.upsertNewsFeed(feed)) != nil
            let result = (try? self.db.allNewsFeeds()) ?? []
            DispatchQueue.main.async {
                self.feeds = result
                completion?(ok)
            }
        }
    }

    func deleteFeed(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.deleteNewsFeed(id: id)
            let result = (try? self.db.allNewsFeeds()) ?? []
            DispatchQueue.main.async { self.feeds = result }
        }
    }

    // MARK: - Article insertion (called from NewsRefreshScheduler)

    /// Insert fetched + labelled articles, skipping duplicates via ON CONFLICT IGNORE.
    /// Returns count of newly inserted articles.
    func insertArticles(_ articles: [NewsArticle]) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                var inserted = 0
                for article in articles {
                    if (try? self.db.insertNewsArticle(article)) != nil { inserted += 1 }
                }
                continuation.resume(returning: inserted)
            }
        }
    }

    // MARK: - Querying

    func loadRecentArticles(limit: Int = 60, feedID: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = (try? self.db.recentArticles(limit: limit, feedID: feedID)) ?? []
            DispatchQueue.main.async { self.articles = result }
        }
    }

    func loadSavedArticles() {
        queue.async { [weak self] in
            guard let self else { return }
            let result = (try? self.db.savedArticles()) ?? []
            DispatchQueue.main.async { self.savedArticles = result }
        }
    }

    /// Fetch a single article by its stable ID.
    func article(id: String) async -> NewsArticle? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let result = (try? self.db.recentArticles(limit: 200, feedID: nil))?
                    .first { $0.id == id }
                continuation.resume(returning: result)
            }
        }
    }

    func articlesForLabel(_ label: NewsLabel, limit: Int = 40) async -> [NewsArticle] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let result = (try? self.db.articlesWithLabel(label.rawValue, limit: limit)) ?? []
                continuation.resume(returning: result)
            }
        }
    }

    func searchArticles(query: String) async -> [NewsArticle] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                let result = (try? self.db.searchNewsArticles(query: query)) ?? []
                continuation.resume(returning: result)
            }
        }
    }

    func recentArticlesSync(limit: Int = 60) -> [NewsArticle] {
        (try? db.recentArticles(limit: limit)) ?? []
    }

    // MARK: - Mutations

    func markRead(articleID: String) {
        queue.async { [weak self] in
            try? self?.db.updateArticleReadStatus(id: articleID, isRead: true)
        }
    }

    func toggleSaved(article: NewsArticle) {
        let newState = !article.isSaved
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.updateArticleSaved(id: article.id, saved: newState)
            let saved = (try? self.db.savedArticles()) ?? []
            DispatchQueue.main.async { self.savedArticles = saved }
        }
    }

    // MARK: - Refresh tracking

    func recordRefresh(feedID: String) {
        lastRefreshDates[feedID] = Date()
    }
}
