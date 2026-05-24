import Foundation

// MARK: - Feed source type

enum NewsSourceType: String, Codable, CaseIterable, Identifiable {
    case rss       // standard RSS 2.0
    case atom      // Atom 1.0
    case hnAlgolia // Hacker News Algolia API

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rss:       return "RSS"
        case .atom:      return "Atom"
        case .hnAlgolia: return "Hacker News"
        }
    }
}

// MARK: - News label (topic classification)

enum NewsLabel: String, Codable, CaseIterable, Identifiable {
    case topStories     = "top_stories"
    case uk             = "uk"
    case world          = "world"
    case business       = "business"
    case technology     = "technology"
    case science        = "science"
    case health         = "health"
    case entertainment  = "entertainment"
    case sports         = "sports"
    case politics       = "politics"
    case finance        = "finance"
    case ai             = "ai"
    case startups       = "startups"
    case design         = "design"
    case environment    = "environment"
    case other          = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topStories:    return "Top Stories"
        case .uk:            return "UK"
        case .world:         return "World"
        case .business:      return "Business"
        case .technology:    return "Technology"
        case .science:       return "Science"
        case .health:        return "Health"
        case .entertainment: return "Entertainment"
        case .sports:        return "Sports"
        case .politics:      return "Politics"
        case .finance:       return "Finance"
        case .ai:            return "AI"
        case .startups:      return "Startups"
        case .design:        return "Design"
        case .environment:   return "Environment"
        case .other:         return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .topStories:    return "star.fill"
        case .uk:            return "flag.fill"
        case .world:         return "globe"
        case .business:      return "briefcase.fill"
        case .technology:    return "cpu.fill"
        case .science:       return "flask.fill"
        case .health:        return "heart.fill"
        case .entertainment: return "film.fill"
        case .sports:        return "sportscourt.fill"
        case .politics:      return "building.columns.fill"
        case .finance:       return "chart.line.uptrend.xyaxis"
        case .ai:            return "sparkles"
        case .startups:      return "bolt.fill"
        case .design:        return "paintbrush.fill"
        case .environment:   return "leaf.fill"
        case .other:         return "ellipsis.circle.fill"
        }
    }

    var accentHex: String {
        switch self {
        case .topStories:    return "#F5C518"
        case .uk:            return "#CF142B"
        case .world:         return "#4A90E2"
        case .business:      return "#50C878"
        case .technology:    return "#7B68EE"
        case .science:       return "#00CED1"
        case .health:        return "#FF6B6B"
        case .entertainment: return "#FF8C00"
        case .sports:        return "#32CD32"
        case .politics:      return "#DC143C"
        case .finance:       return "#FFD700"
        case .ai:            return "#9B59B6"
        case .startups:      return "#F39C12"
        case .design:        return "#E74C3C"
        case .environment:   return "#27AE60"
        case .other:         return "#7F8C8D"
        }
    }
}

// MARK: - News feed

struct NewsFeed: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var category: String
    var enabled: Bool
    var refreshIntervalMinutes: Int
    var sourceType: NewsSourceType
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        category: String = "",
        enabled: Bool = true,
        refreshIntervalMinutes: Int = 30,
        sourceType: NewsSourceType = .rss,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.enabled = enabled
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - News article

struct NewsArticle: Identifiable, Codable, Equatable {
    var id: String
    var feedID: String
    var sourceName: String
    var title: String
    var url: String
    var publishedAt: Date
    var fetchedAt: Date
    var summary: String
    var contentExcerpt: String
    var labels: [NewsLabel]
    var importanceScore: Double
    var isRead: Bool
    var isSaved: Bool
    var isIgnored: Bool
    var dedupeKey: String

    init(
        id: String = UUID().uuidString,
        feedID: String,
        sourceName: String,
        title: String,
        url: String,
        publishedAt: Date = Date(),
        fetchedAt: Date = Date(),
        summary: String = "",
        contentExcerpt: String = "",
        labels: [NewsLabel] = [],
        importanceScore: Double = 0.5,
        isRead: Bool = false,
        isSaved: Bool = false,
        isIgnored: Bool = false,
        dedupeKey: String = ""
    ) {
        self.id = id
        self.feedID = feedID
        self.sourceName = sourceName
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.summary = summary
        self.contentExcerpt = contentExcerpt
        self.labels = labels
        self.importanceScore = importanceScore
        self.isRead = isRead
        self.isSaved = isSaved
        self.isIgnored = isIgnored
        self.dedupeKey = dedupeKey.isEmpty ? Self.makeDedupeKey(url: url, title: title) : dedupeKey
    }

    static func makeDedupeKey(url: String, title: String) -> String {
        let normalized = url.trimmingCharacters(in: .whitespaces).lowercased()
        if !normalized.isEmpty { return normalized }
        let titleKey = title.lowercased().filter { $0.isLetter || $0.isNumber }
        if !titleKey.isEmpty { return titleKey }
        // Both URL and title are empty/whitespace-only — generate a stable
        // fallback so dedupeKey is never empty (an empty key would allow
        // the same article to match every other article with an empty key).
        return "unknown_\(UUID().uuidString)"
    }
}

// MARK: - Parsed feed item (intermediate — before DB insertion)

struct ParsedFeedItem {
    let title: String
    let link: String
    let description: String
    let pubDate: Date?
    let guid: String
    let author: String
}

// MARK: - Watch mode config

struct FeedWatchConfig: Codable {
    var feedID: String
    var notifyOnNew: Bool
    var labelFilter: NewsLabel?
    var minImportance: Double
    var lastChecked: Date

    init(feedID: String, labelFilter: NewsLabel? = nil) {
        self.feedID = feedID
        self.notifyOnNew = true
        self.labelFilter = labelFilter
        self.minImportance = 0.4
        self.lastChecked = Date()
    }
}

// MARK: - Refresh result

struct FeedRefreshResult {
    let feedID: String
    let feedName: String
    let newArticleCount: Int
    let totalFetched: Int
    let error: String?
    let duration: TimeInterval
}
