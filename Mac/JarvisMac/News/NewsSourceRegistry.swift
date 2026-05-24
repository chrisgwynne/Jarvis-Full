import Foundation

/// Built-in default feed catalogue. User can add/edit/remove via settings;
/// these are seeded once on first run only.
enum NewsSourceRegistry {

    static let defaultFeeds: [NewsFeed] = [
        // BBC
        NewsFeed(
            id: "bbc_frontpage",
            name: "BBC News",
            url: "https://feeds.bbci.co.uk/news/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),
        NewsFeed(
            id: "bbc_uk",
            name: "BBC UK",
            url: "https://feeds.bbci.co.uk/news/uk/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),
        NewsFeed(
            id: "bbc_world",
            name: "BBC World",
            url: "https://feeds.bbci.co.uk/news/world/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),
        NewsFeed(
            id: "bbc_business",
            name: "BBC Business",
            url: "https://feeds.bbci.co.uk/news/business/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),
        NewsFeed(
            id: "bbc_technology",
            name: "BBC Technology",
            url: "https://feeds.bbci.co.uk/news/technology/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),
        NewsFeed(
            id: "bbc_wales",
            name: "BBC Wales",
            url: "https://feeds.bbci.co.uk/news/wales/rss.xml",
            category: "bbc",
            refreshIntervalMinutes: 60,
            sourceType: .rss
        ),

        // Bloomberg (Google News RSS fallback — no official Bloomberg RSS)
        NewsFeed(
            id: "bloomberg_gnews",
            name: "Bloomberg (via Google News)",
            url: "https://news.google.com/rss/search?q=bloomberg&hl=en-GB&gl=GB&ceid=GB:en",
            category: "bloomberg",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),

        // AP News (replaces Reuters — Reuters killed public RSS)
        NewsFeed(
            id: "reuters_top",
            name: "AP Top News",
            url: "https://feeds.apnews.com/rss/apf-topnews",
            category: "reuters",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),

        // The Guardian
        NewsFeed(
            id: "guardian_top",
            name: "The Guardian",
            url: "https://www.theguardian.com/uk/rss",
            category: "guardian",
            refreshIntervalMinutes: 30,
            sourceType: .rss
        ),

        // The Verge
        NewsFeed(
            id: "verge_top",
            name: "The Verge",
            url: "https://www.theverge.com/rss/index.xml",
            category: "tech",
            refreshIntervalMinutes: 30,
            sourceType: .atom
        ),

        // Hacker News (Algolia API → treated as RSS by fetcher)
        NewsFeed(
            id: "hn_top",
            name: "Hacker News",
            url: "https://hnrss.org/frontpage",
            category: "tech",
            refreshIntervalMinutes: 60,
            sourceType: .rss
        ),
    ]

    /// Feed ID → canonical label hint used by labeller as seed.
    static let feedLabelHints: [String: [NewsLabel]] = [
        "bbc_frontpage":   [.topStories, .uk, .world],
        "bbc_uk":          [.uk],
        "bbc_world":       [.world],
        "bbc_business":    [.business, .finance],
        "bbc_technology":  [.technology],
        "bbc_wales":       [.uk],
        "bloomberg_gnews": [.finance, .business],
        "reuters_top":     [.world, .topStories],
        "guardian_top":    [.uk, .world, .politics],
        "verge_top":       [.technology, .startups, .design],
        "hn_top":          [.technology, .startups, .ai],
    ]
}
