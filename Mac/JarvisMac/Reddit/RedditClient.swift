import Foundation

/// Errors surfaced by `RedditClient`.  The public-facing UI distinguishes
/// "this subreddit doesn't exist" from "Reddit rate-limited us" so the
/// user can recover with the right action.
enum RedditClientError: LocalizedError {
    case invalidSubreddit(String)
    case notFound(String)
    case forbidden(String)        // private / quarantined / banned
    case rateLimited
    case http(Int, String)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidSubreddit(let s): return "Invalid subreddit name: \(s)"
        case .notFound(let s):         return "Subreddit r/\(s) was not found."
        case .forbidden(let s):        return "r/\(s) is private, quarantined, or banned."
        case .rateLimited:             return "Reddit is rate-limiting requests; try again shortly."
        case .http(let c, let m):      return "HTTP \(c): \(m)"
        case .network(let m):          return "Network error: \(m)"
        case .decode(let m):           return "Could not parse Reddit response: \(m)"
        }
    }
}

/// Stateless fetcher for Reddit's public `*.json` endpoints.  No OAuth,
/// no comment trees deeper than the caller asks for, no infinite refresh
/// loops — each call is one-shot and pays its own rate-limit budget.
///
/// Reddit lets unauthenticated clients hit the `*.json` endpoints with
/// a clear `User-Agent`; staying under their soft 60-rpm ceiling is the
/// caller's job (see `RedditStore.refreshAllEnabledSources()` for the
/// throttling logic).
actor RedditClient {
    /// Reddit requires a descriptive UA — anonymous browsers get
    /// aggressive rate-limiting and frequent 429s.
    static let userAgent =
        "macOS:com.jarvis.mac:v1.0 (by /u/jarvis-mac)"

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public

    /// Fetch the most-recent posts for one configured source.
    /// Honours sortMode + timeRange + limit + NSFW filter.
    func fetchSubreddit(_ source: RedditSource) async throws -> [RedditPost] {
        guard let name = RedditSource.normalise(name: source.subreddit) else {
            throw RedditClientError.invalidSubreddit(source.subreddit)
        }
        let limit = max(1, min(source.limit, 100))
        var path = "https://www.reddit.com/r/\(name)/\(source.sortMode.rawValue).json?limit=\(limit)&raw_json=1"
        if source.sortMode == .top {
            path += "&t=\(source.timeRange.rawValue)"
        }
        let json = try await getJSON(path: path)
        let posts = try parsePostListing(json, sourceId: source.id, subreddit: name)
        if source.includeNSFW { return posts }
        return posts.filter { !$0.isNSFW }
    }

    /// Fetch top-level + first-page comments for a post.  Caps the total
    /// number returned so a thread with 5 000 comments doesn't blow the
    /// LLM context budget.
    func fetchPostComments(post: RedditPost, maxComments: Int = 60)
        async throws -> [RedditComment]
    {
        // Reddit comment URLs follow /r/{sub}/comments/{id}/_/.json
        let path = "https://www.reddit.com\(post.permalink).json?limit=\(maxComments)&raw_json=1&depth=4"
        let json = try await getJSON(path: path)
        return try parseCommentTree(json, postId: post.id, cap: maxComments)
    }

    /// Search across one or more configured subreddits.  Implemented as a
    /// per-source `search.json?q=…&restrict_sr=on` call, fanned out and
    /// merged.  Best-effort — any single source failing is logged and
    /// skipped.
    func searchConfiguredSubreddits(query: String,
                                     sources: [RedditSource],
                                     limitPerSource: Int = 10
    ) async -> (posts: [RedditPost], errors: [String]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed

        var merged: [RedditPost] = []
        var errors: [String]    = []
        for source in sources where source.enabled {
            guard let name = RedditSource.normalise(name: source.subreddit) else { continue }
            let path = "https://www.reddit.com/r/\(name)/search.json?q=\(q)&restrict_sr=on&sort=relevance&limit=\(limitPerSource)&raw_json=1"
            do {
                let json = try await getJSON(path: path)
                let posts = try parsePostListing(json,
                                                  sourceId: source.id,
                                                  subreddit: name)
                let filtered = source.includeNSFW
                    ? posts
                    : posts.filter { !$0.isNSFW }
                merged.append(contentsOf: filtered)
            } catch {
                errors.append("r/\(name): \(error.localizedDescription)")
            }
        }
        merged.sort { $0.score > $1.score }
        return (merged, errors)
    }

    // MARK: - Networking

    private func getJSON(path: String, attempt: Int = 1) async throws -> Any {
        guard let url = URL(string: path) else {
            throw RedditClientError.network("Bad URL: \(path)")
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw RedditClientError.network("Non-HTTP response")
            }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try JSONSerialization.jsonObject(
                        with: data, options: [.allowFragments])
                } catch {
                    throw RedditClientError.decode(error.localizedDescription)
                }
            case 404:
                throw RedditClientError.notFound(extractSubreddit(from: path))
            case 403, 451:
                throw RedditClientError.forbidden(extractSubreddit(from: path))
            case 429:
                // Honour rate-limit with one polite retry, then give up.
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    return try await getJSON(path: path, attempt: attempt + 1)
                }
                throw RedditClientError.rateLimited
            case 500..<600:
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return try await getJSON(path: path, attempt: attempt + 1)
                }
                throw RedditClientError.http(http.statusCode, "Server error")
            default:
                throw RedditClientError.http(http.statusCode, "")
            }
        } catch let e as RedditClientError {
            throw e
        } catch {
            throw RedditClientError.network(error.localizedDescription)
        }
    }

    private func extractSubreddit(from path: String) -> String {
        // Best-effort — `/r/name/…` slice.
        guard let r = path.range(of: "/r/") else { return "?" }
        let rest = path[r.upperBound...]
        return rest.split(separator: "/").first.map(String.init) ?? "?"
    }

    // MARK: - Parsing

    /// Parse a `{kind: "Listing", data: {children: [{kind:"t3", data:{…}}]}}`
    /// payload into `RedditPost` values.
    private func parsePostListing(_ raw: Any,
                                   sourceId: String,
                                   subreddit: String) throws -> [RedditPost]
    {
        guard
            let root = raw as? [String: Any],
            let data = root["data"] as? [String: Any],
            let children = data["children"] as? [[String: Any]]
        else {
            throw RedditClientError.decode("Unexpected listing shape")
        }
        var result: [RedditPost] = []
        for child in children {
            guard child["kind"] as? String == "t3",
                  let d = child["data"] as? [String: Any],
                  let id = d["id"] as? String,
                  let title = d["title"] as? String
            else { continue }
            let permalink = (d["permalink"] as? String) ?? "/r/\(subreddit)/comments/\(id)/"
            let url       = (d["url"] as? String)
                ?? (d["url_overridden_by_dest"] as? String)
                ?? "https://www.reddit.com\(permalink)"
            let created   = (d["created_utc"] as? Double) ?? 0
            let nsfw      = (d["over_18"] as? Bool) ?? false
            let thumb     = d["thumbnail"] as? String
            let post = RedditPost(
                id: id,
                subreddit: (d["subreddit"] as? String) ?? subreddit,
                title: title,
                author: (d["author"] as? String) ?? "[deleted]",
                score: (d["score"] as? Int) ?? 0,
                commentsCount: (d["num_comments"] as? Int) ?? 0,
                url: url,
                permalink: permalink,
                selfText: (d["selftext"] as? String) ?? "",
                thumbnail: (thumb == "self" || thumb == "default"
                            || thumb == "nsfw" || thumb == "") ? nil : thumb,
                createdAt: Date(timeIntervalSince1970: created),
                flair: d["link_flair_text"] as? String,
                isVideo: (d["is_video"] as? Bool) ?? false,
                isNSFW: nsfw,
                sourceId: sourceId
            )
            result.append(post)
        }
        return result
    }

    /// Parse `/r/{sub}/comments/{id}/_.json` — a two-element array where
    /// the first is the post and the second is the comment listing.
    private func parseCommentTree(_ raw: Any, postId: String, cap: Int)
        throws -> [RedditComment]
    {
        guard
            let arr = raw as? [Any],
            arr.count >= 2,
            let listing = arr[1] as? [String: Any],
            let data    = listing["data"] as? [String: Any],
            let children = data["children"] as? [[String: Any]]
        else {
            throw RedditClientError.decode("Unexpected comments shape")
        }
        var result: [RedditComment] = []
        for child in children {
            if result.count >= cap { break }
            collectComment(child, postId: postId, parent: nil, depth: 0,
                           into: &result, cap: cap)
        }
        return result
    }

    private func collectComment(_ child: [String: Any],
                                 postId: String,
                                 parent: String?,
                                 depth: Int,
                                 into result: inout [RedditComment],
                                 cap: Int)
    {
        guard child["kind"] as? String == "t1",
              let d = child["data"] as? [String: Any],
              let id = d["id"] as? String,
              let body = d["body"] as? String
        else { return }
        let comment = RedditComment(
            id: id,
            postId: postId,
            parentId: parent,
            author: (d["author"] as? String) ?? "[deleted]",
            body: body,
            score: (d["score"] as? Int) ?? 0,
            createdAt: Date(timeIntervalSince1970:
                (d["created_utc"] as? Double) ?? 0),
            permalink: (d["permalink"] as? String) ?? "",
            depth: depth
        )
        result.append(comment)
        if result.count >= cap { return }
        // Recurse into `replies` (which can be "" if no replies).
        if let replies = d["replies"] as? [String: Any],
           let rdata  = replies["data"] as? [String: Any],
           let rchildren = rdata["children"] as? [[String: Any]] {
            for r in rchildren {
                if result.count >= cap { break }
                collectComment(r, postId: postId, parent: id,
                               depth: depth + 1, into: &result, cap: cap)
            }
        }
    }
}
