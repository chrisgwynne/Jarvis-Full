import Foundation

/// A configured subreddit the user has added to Jarvis.  Persisted by
/// `RedditStore` to `~/Library/Application Support/JarvisMac/reddit_sources.json`.
/// `subreddit` is stored without the `r/` prefix and lowercased so dedup
/// and URL building are deterministic regardless of how the user typed
/// it in Settings.
struct RedditSource: Identifiable, Codable, Equatable {
    enum SortMode: String, Codable, CaseIterable, Identifiable {
        case hot, top, new, rising
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum TimeRange: String, Codable, CaseIterable, Identifiable {
        case hour, day, week, month, year, all
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .hour:  return "Past Hour"
            case .day:   return "Past Day"
            case .week:  return "Past Week"
            case .month: return "Past Month"
            case .year:  return "Past Year"
            case .all:   return "All Time"
            }
        }
    }

    let id: String
    var subreddit: String
    var displayName: String
    var enabled: Bool = true
    var sortMode: SortMode = .hot
    var timeRange: TimeRange = .day
    var limit: Int = 25
    var includeNSFW: Bool = false
    var refreshIntervalMinutes: Int = 30
    /// Free-form tags used by the overlay grouping ("tech", "biz" …).
    var tags: [String] = []
    /// Higher = surfaced earlier in cross-subreddit "top Reddits" view.
    var priority: Int = 0

    /// Trims `r/` prefix and whitespace, lowercases, drops anything that
    /// isn't a valid subreddit character.  Returns nil if the result is
    /// empty.
    static func normalise(name: String) -> String? {
        var t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("r/") { t = String(t.dropFirst(2)) }
        if t.lowercased().hasPrefix("/r/") { t = String(t.dropFirst(3)) }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let cleaned = t.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).lowercased()
        return result.isEmpty ? nil : result
    }
}

/// A single Reddit post.  Mapped from the JSON `Link` kind in the
/// `t3_…` slice of `/r/{sub}/{sort}.json`.
struct RedditPost: Identifiable, Codable, Equatable {
    let id: String                  // e.g. "1abc23"  (no t3_ prefix)
    let subreddit: String
    var title: String
    var author: String
    var score: Int
    var commentsCount: Int
    var url: String                 // outbound link (might be self)
    var permalink: String           // reddit.com/r/.../comments/...
    var selfText: String            // markdown body, may be empty
    var thumbnail: String?          // resolvable URL or nil
    var createdAt: Date
    var flair: String?
    var isVideo: Bool
    var isNSFW: Bool
    /// `RedditSource.id` this post came from (so the overlay can filter
    /// by source even after cache merges).
    var sourceId: String
}

/// Which slice the Reddit overlay should display.  Lives here (not in
/// the view) so JarvisController + AppState can drive the overlay
/// without importing UI code.
enum RedditOverlayMode: Equatable {
    case feed                  // newest across every enabled source
    case top                   // score-sorted across every enabled source
    case subreddit(String)     // one RedditSource.id
    case search(String)        // search query (results live in store.posts)
}

/// A flattened Reddit comment.  Trees are flattened to depth-N children
/// for the summariser; `parentId` lets a UI re-nest if it wants to.
struct RedditComment: Identifiable, Codable, Equatable {
    let id: String
    var postId: String
    var parentId: String?           // nil for top-level
    var author: String
    var body: String
    var score: Int
    var createdAt: Date
    var permalink: String
    var depth: Int = 0
}
