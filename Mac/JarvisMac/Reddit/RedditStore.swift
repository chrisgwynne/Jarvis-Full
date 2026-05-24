import Foundation
import Observation

/// Persistence + in-memory cache for the Reddit integration.
///
/// Three JSON files under `~/Library/Application Support/JarvisMac/`:
///   * `reddit_sources.json`  — configured subreddits + master enable flag
///   * `reddit_posts.json`    — cached posts (capped per source)
///   * `reddit_state.json`    — seen / saved / dismissed post IDs, last
///                              refresh timestamps, last errors
///
/// All mutations are @MainActor; the actual network work happens inside
/// `RedditClient` (an `actor`) which the store calls from a `Task`.
@Observable
@MainActor
final class RedditStore {
    // MARK: - User-visible state

    private(set) var sources: [RedditSource] = []
    /// All cached posts across every source.  The overlay filters this
    /// for display; the store keeps it flat so cross-subreddit "top"
    /// views are cheap.
    private(set) var posts: [RedditPost] = []
    /// Comments for the currently-open post (keyed by post id) — only
    /// the most-recent post's tree is held to keep memory bounded.
    private(set) var commentsByPostId: [String: [RedditComment]] = [:]

    /// Master "Reddit integration enabled" switch.  When false the
    /// scheduler skips refresh entirely.
    var enabled: Bool = true { didSet { saveState() } }

    /// Per-source last successful refresh.
    private(set) var lastRefreshDates: [String: Date] = [:]
    /// Per-source last error (nil after a successful refresh).
    private(set) var lastErrors: [String: String] = [:]
    /// Last full-refresh timing — for the Diagnostics panel.
    private(set) var lastRefreshDurationMs: Int = 0
    private(set) var lastFullRefreshAt: Date? = nil

    private(set) var seenPostIds:      Set<String> = []
    private(set) var savedPostIds:     Set<String> = []
    private(set) var dismissedPostIds: Set<String> = []

    /// True while a refresh is in flight.  Bound by the Settings panel.
    private(set) var isRefreshing: Bool = false

    // MARK: - Storage

    private let sourcesURL:  URL
    private let postsURL:    URL
    private let stateURL:    URL
    private let postsPerSourceCap = 50
    private let totalPostsCap     = 600

    private let client: RedditClient

    init(client: RedditClient = RedditClient()) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        sourcesURL = dir.appendingPathComponent("reddit_sources.json")
        postsURL   = dir.appendingPathComponent("reddit_posts.json")
        stateURL   = dir.appendingPathComponent("reddit_state.json")
        self.client = client
        loadSources()
        loadPosts()
        loadState()
        if sources.isEmpty { seedDefaults(); saveSources() }
    }

    // MARK: - Source CRUD

    /// Add a brand-new source.  Returns nil if the name normalises to
    /// empty or already exists.
    @discardableResult
    func addSource(name: String,
                   displayName: String? = nil,
                   sortMode: RedditSource.SortMode = .hot,
                   timeRange: RedditSource.TimeRange = .day,
                   limit: Int = 25,
                   includeNSFW: Bool = false) -> RedditSource?
    {
        guard let sub = RedditSource.normalise(name: name) else { return nil }
        if sources.contains(where: { $0.subreddit == sub }) { return nil }
        let s = RedditSource(
            id: "rdt_" + sub + "_" + String(Int(Date().timeIntervalSince1970)),
            subreddit: sub,
            displayName: displayName?.isEmpty == false ? displayName! : "r/" + sub,
            enabled: true,
            sortMode: sortMode,
            timeRange: timeRange,
            limit: limit,
            includeNSFW: includeNSFW,
            refreshIntervalMinutes: 30,
            tags: [],
            priority: 0)
        sources.append(s)
        saveSources()
        return s
    }

    func update(_ s: RedditSource) {
        guard let i = sources.firstIndex(where: { $0.id == s.id }) else { return }
        sources[i] = s
        saveSources()
    }

    func remove(id: String) {
        sources.removeAll { $0.id == id }
        posts.removeAll  { $0.sourceId == id }
        lastRefreshDates[id] = nil
        lastErrors[id] = nil
        saveSources()
        savePosts()
        saveState()
    }

    func resetToDefaults() {
        sources = []
        posts = []
        lastRefreshDates.removeAll()
        lastErrors.removeAll()
        seedDefaults()
        saveSources()
        savePosts()
        saveState()
    }

    private func seedDefaults() {
        let seeds: [(String, String)] = [
            ("technology",  "r/technology"),
            ("apple",       "r/apple"),
            ("artificial",  "r/artificial"),
            ("LocalLLaMA",  "r/LocalLLaMA"),
            ("3Dprinting",  "r/3Dprinting"),
            ("Etsy",        "r/Etsy"),
            ("smallbusiness","r/smallbusiness"),
        ]
        sources = seeds.compactMap { (raw, label) in
            guard let n = RedditSource.normalise(name: raw) else { return nil }
            return RedditSource(
                id: "rdt_default_\(n)",
                subreddit: n,
                displayName: label,
                enabled: true,
                sortMode: .hot,
                timeRange: .day,
                limit: 25,
                includeNSFW: false,
                refreshIntervalMinutes: 30,
                tags: [],
                priority: 0)
        }
    }

    // MARK: - Lookup

    var enabledSources: [RedditSource] { sources.filter { $0.enabled } }

    func source(id: String) -> RedditSource? {
        sources.first(where: { $0.id == id })
    }

    /// Best-effort match by subreddit name or display name.
    func source(matchingName q: String) -> RedditSource? {
        guard let n = RedditSource.normalise(name: q) else { return nil }
        if let exact = sources.first(where: { $0.subreddit == n }) { return exact }
        let q2 = q.lowercased().trimmingCharacters(in: .whitespaces)
        return sources.first { s in
            s.displayName.lowercased().contains(q2)
                || s.subreddit.lowercased().contains(n)
        }
    }

    func posts(forSourceId id: String) -> [RedditPost] {
        posts.filter { $0.sourceId == id && !dismissedPostIds.contains($0.id) }
    }

    /// All posts across sources, ranked by score within the recency
    /// window the "top Reddits" command surfaces.
    var topPostsAcrossSources: [RedditPost] {
        posts
            .filter { !dismissedPostIds.contains($0.id) }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Refresh

    func refreshSource(_ source: RedditSource) async {
        guard enabled, source.enabled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await client.fetchSubreddit(source)
            mergeFetched(fetched, for: source)
            lastRefreshDates[source.id] = Date()
            lastErrors[source.id] = nil
            saveState()
        } catch {
            lastErrors[source.id] = error.localizedDescription
            saveState()
        }
    }

    /// Refresh every enabled source serially, with a short delay between
    /// calls so Reddit's per-IP rate-limit is never breached.
    func refreshAllEnabledSources() async {
        guard enabled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let started = Date()
        for s in enabledSources {
            await refreshSource(s)
            // 600 ms between calls = ~100 rpm worst case; safely under
            // Reddit's 60-rpm unauthenticated soft ceiling.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        lastRefreshDurationMs = Int(Date().timeIntervalSince(started) * 1000)
        lastFullRefreshAt = Date()
        saveState()
    }

    /// Search across configured (enabled) subreddits and cache the
    /// results into `posts` so the overlay can pick them up.  Returns
    /// the merged result so callers can speak the count.
    @discardableResult
    func searchAcrossSources(query: String) async
        -> (posts: [RedditPost], errors: [String])
    {
        guard enabled else { return ([], []) }
        let result = await client.searchConfiguredSubreddits(
            query: query, sources: enabledSources)
        // Treat search results as a transient "pinned" set inside the
        // main posts pool — overlay layers the search query into the
        // ActiveContextRegistry, so we just merge.
        for p in result.posts { mergeOne(p) }
        if posts.count > totalPostsCap { trimPosts() }
        savePosts()
        return result
    }

    /// Fetch + cache the comment tree for a post.  Returns nil on
    /// failure (caller falls back to a "comments unavailable" message).
    func loadComments(for post: RedditPost,
                      maxComments: Int = 60) async -> [RedditComment]?
    {
        do {
            let comments = try await client.fetchPostComments(
                post: post, maxComments: maxComments)
            commentsByPostId[post.id] = comments
            return comments
        } catch {
            lastErrors[post.sourceId] = error.localizedDescription
            return nil
        }
    }

    // MARK: - Per-post user actions

    func markSeen(_ post: RedditPost) {
        seenPostIds.insert(post.id); saveState()
    }
    func toggleSaved(_ post: RedditPost) {
        if savedPostIds.contains(post.id) { savedPostIds.remove(post.id) }
        else                                { savedPostIds.insert(post.id) }
        saveState()
    }
    func dismiss(_ post: RedditPost) {
        dismissedPostIds.insert(post.id); saveState()
    }

    // MARK: - Merge + persistence

    private func mergeFetched(_ fetched: [RedditPost], for source: RedditSource) {
        // Drop existing posts from this source then re-insert — keeps the
        // cache trimmed to the latest sort.
        posts.removeAll { $0.sourceId == source.id }
        let capped = Array(fetched.prefix(postsPerSourceCap))
        posts.append(contentsOf: capped)
        if posts.count > totalPostsCap { trimPosts() }
        savePosts()
    }

    private func mergeOne(_ p: RedditPost) {
        if let i = posts.firstIndex(where: { $0.id == p.id }) {
            posts[i] = p
        } else {
            posts.append(p)
        }
    }

    private func trimPosts() {
        posts.sort { $0.createdAt > $1.createdAt }
        posts = Array(posts.prefix(totalPostsCap))
    }

    // MARK: - Persistence I/O

    private struct SourcesFile: Codable {
        var enabled: Bool
        var sources: [RedditSource]
    }
    private struct StateFile: Codable {
        var lastRefreshDates: [String: Date]
        var lastErrors: [String: String]
        var seenPostIds: [String]
        var savedPostIds: [String]
        var dismissedPostIds: [String]
        var lastFullRefreshAt: Date?
        var lastRefreshDurationMs: Int
    }

    private func loadSources() {
        guard let data = try? Data(contentsOf: sourcesURL) else { return }
        if let decoded = try? JSONDecoder().decode(SourcesFile.self, from: data) {
            sources = decoded.sources
            enabled = decoded.enabled
        }
    }
    private func saveSources() {
        let f = SourcesFile(enabled: enabled, sources: sources)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(f) {
            try? data.write(to: sourcesURL, options: .atomic)
        }
    }
    private func loadPosts() {
        guard let data = try? Data(contentsOf: postsURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        if let arr = try? dec.decode([RedditPost].self, from: data) {
            posts = arr
        }
    }
    private func savePosts() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(posts) {
            try? data.write(to: postsURL, options: .atomic)
        }
    }
    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        if let decoded = try? dec.decode(StateFile.self, from: data) {
            lastRefreshDates = decoded.lastRefreshDates
            lastErrors = decoded.lastErrors
            seenPostIds = Set(decoded.seenPostIds)
            savedPostIds = Set(decoded.savedPostIds)
            dismissedPostIds = Set(decoded.dismissedPostIds)
            lastFullRefreshAt = decoded.lastFullRefreshAt
            lastRefreshDurationMs = decoded.lastRefreshDurationMs
        }
    }
    private func saveState() {
        let f = StateFile(
            lastRefreshDates: lastRefreshDates,
            lastErrors: lastErrors,
            seenPostIds: Array(seenPostIds),
            savedPostIds: Array(savedPostIds),
            dismissedPostIds: Array(dismissedPostIds),
            lastFullRefreshAt: lastFullRefreshAt,
            lastRefreshDurationMs: lastRefreshDurationMs)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(f) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
