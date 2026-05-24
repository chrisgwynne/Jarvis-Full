import Foundation

/// Fetches and parses a single feed URL. Async, URLSession-based.
/// Handles RSS, Atom, and the Hacker News Algolia endpoint.
enum RSSFetcher {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Jarvis/1.0 (macOS; RSS Reader)"
        ]
        return URLSession(configuration: cfg)
    }()

    /// Fetch + parse a feed, returning raw `ParsedFeedItem` list.
    static func fetch(feed: NewsFeed) async throws -> [ParsedFeedItem] {
        guard let url = URL(string: feed.url) else {
            throw RSSFetchError.invalidURL(feed.url)
        }

        switch feed.sourceType {
        case .rss, .atom:
            return try await fetchXML(url: url)
        case .hnAlgolia:
            return try await fetchHNAlgolia(url: url)
        }
    }

    // MARK: - XML (RSS + Atom)

    private static func fetchXML(url: URL) async throws -> [ParsedFeedItem] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw RSSFetchError.networkError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RSSFetchError.httpError(http.statusCode)
        }
        return try RSSParser.parse(data: data)
    }

    // MARK: - Hacker News Algolia JSON API

    private static func fetchHNAlgolia(url: URL) async throws -> [ParsedFeedItem] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw RSSFetchError.networkError("HN API error")
        }

        // Algolia response: {"hits": [{"objectID","title","url","created_at","points",...}]}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            // Fallback: some HN RSS endpoints return XML
            return try RSSParser.parse(data: data)
        }

        let iso = ISO8601DateFormatter()
        return hits.compactMap { hit -> ParsedFeedItem? in
            guard let title = hit["title"] as? String else { return nil }
            let link = (hit["url"] as? String) ?? "https://news.ycombinator.com/item?id=\(hit["objectID"] as? String ?? "")"
            let dateStr = hit["created_at"] as? String ?? ""
            let pubDate = iso.date(from: dateStr)
            let points = hit["points"] as? Int ?? 0
            let comments = hit["num_comments"] as? Int ?? 0
            let desc = "\(points) points · \(comments) comments"
            let guid = hit["objectID"] as? String ?? link
            return ParsedFeedItem(title: title, link: link, description: desc, pubDate: pubDate, guid: guid, author: "")
        }
    }
}

enum RSSFetchError: LocalizedError {
    case invalidURL(String)
    case networkError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u):    return "Invalid URL: \(u)"
        case .networkError(let m):  return "Network error: \(m)"
        case .httpError(let code):  return "HTTP \(code)"
        }
    }
}
