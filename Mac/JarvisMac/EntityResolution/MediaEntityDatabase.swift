import Foundation

// MARK: - MediaEntityDatabase

/// Built-in database of well-known media, news, and streaming entities with aliases.
/// Phonetic variants and common misspellings are listed as aliases so the
/// fuzzy matcher can pick them up even without phonetic fallback.
enum MediaEntityDatabase {

    struct Entry {
        let id: String
        let displayName: String
        let entityType: EntityType
        let url: String
        let aliases: [String]
        let bundleID: String?

        init(_ id: String, _ name: String, _ type: EntityType,
             url: String, aliases: [String] = [], bundleID: String? = nil) {
            self.id = id
            self.displayName = name
            self.entityType = type
            self.url = url
            self.aliases = aliases
            self.bundleID = bundleID
        }
    }

    // MARK: - News Channels

    static let newsChannels: [Entry] = [
        Entry("euronews", "EuroNews",       .newsChannel,
              url: "https://www.euronews.com",
              aliases: ["euro news", "euronews", "european news", "euronews.com", "euro"]),

        Entry("bbc_news", "BBC News",       .newsChannel,
              url: "https://www.bbc.co.uk/news",
              aliases: ["bbc", "bbc1", "bbc news", "british broadcasting corporation", "bbc.co.uk"]),

        Entry("sky_news", "Sky News",       .newsChannel,
              url: "https://news.sky.com",
              aliases: ["sky news", "skynews", "sky"]),

        Entry("sky_sports", "Sky Sports",   .newsChannel,
              url: "https://www.skysports.com",
              aliases: ["sky sports", "skysports", "sky sport", "sky sports news"]),

        Entry("cnn", "CNN",                 .newsChannel,
              url: "https://www.cnn.com",
              aliases: ["cnn", "cable news network"]),

        Entry("fox_news", "Fox News",       .newsChannel,
              url: "https://www.foxnews.com",
              aliases: ["fox news", "fox", "foxnews"]),

        Entry("al_jazeera", "Al Jazeera",   .newsChannel,
              url: "https://www.aljazeera.com",
              aliases: ["al jazeera", "aljazeera", "al-jazeera", "qatar news"]),

        Entry("reuters", "Reuters",         .newsChannel,
              url: "https://www.reuters.com",
              aliases: ["reuters", "reuters news"]),

        Entry("bloomberg", "Bloomberg",     .newsChannel,
              url: "https://www.bloomberg.com",
              aliases: ["bloomberg", "bloomberg news", "bloomberg finance"]),

        Entry("guardian", "The Guardian",   .newsChannel,
              url: "https://www.theguardian.com",
              aliases: ["guardian", "the guardian", "guardian news"]),

        Entry("telegraph", "The Telegraph", .newsChannel,
              url: "https://www.telegraph.co.uk",
              aliases: ["telegraph", "the telegraph", "daily telegraph"]),

        Entry("times", "The Times",         .newsChannel,
              url: "https://www.thetimes.co.uk",
              aliases: ["times", "the times"]),

        Entry("cnbc", "CNBC",               .newsChannel,
              url: "https://www.cnbc.com",
              aliases: ["cnbc", "consumer news business channel"]),

        Entry("nbc_news", "NBC News",       .newsChannel,
              url: "https://www.nbcnews.com",
              aliases: ["nbc news", "nbc", "national broadcasting company"]),

        Entry("abc_news", "ABC News",       .newsChannel,
              url: "https://abcnews.go.com",
              aliases: ["abc news", "abc", "american broadcasting company news"]),

        Entry("cbs_news", "CBS News",       .newsChannel,
              url: "https://www.cbsnews.com",
              aliases: ["cbs news", "cbs"]),

        Entry("tbn_sports", "TNT Sports",   .newsChannel,
              url: "https://www.tntsports.co.uk",
              aliases: ["tnt sports", "tnt sport", "bt sport", "discovery sport"]),

        Entry("espn", "ESPN",               .newsChannel,
              url: "https://www.espn.com",
              aliases: ["espn", "e s p n", "entertainment and sports programming network"]),

        Entry("independent", "The Independent", .newsChannel,
              url: "https://www.independent.co.uk",
              aliases: ["independent", "the independent"]),

        Entry("dailymail", "Daily Mail",    .newsChannel,
              url: "https://www.dailymail.co.uk",
              aliases: ["daily mail", "dailymail", "mail online"]),

        Entry("politico", "Politico",       .newsChannel,
              url: "https://www.politico.com",
              aliases: ["politico", "politico news"]),

        Entry("techcrunch", "TechCrunch",   .newsChannel,
              url: "https://techcrunch.com",
              aliases: ["techcrunch", "tech crunch"]),

        Entry("wired", "Wired",             .newsChannel,
              url: "https://www.wired.com",
              aliases: ["wired", "wired magazine", "wired news"]),

        Entry("verge", "The Verge",         .newsChannel,
              url: "https://www.theverge.com",
              aliases: ["the verge", "verge", "theverge"]),

        Entry("hacker_news", "Hacker News", .newsChannel,
              url: "https://news.ycombinator.com",
              aliases: ["hacker news", "ycombinator", "hacker news ycombinator", "hn"]),
    ]

    // MARK: - Streaming & Media

    static let streamingServices: [Entry] = [
        Entry("youtube", "YouTube",         .youtubeChannel,
              url: "https://www.youtube.com",
              aliases: ["youtube", "you tube", "yt"],
              bundleID: "com.google.ios.youtube"),

        Entry("netflix", "Netflix",         .stream,
              url: "https://www.netflix.com",
              aliases: ["netflix", "net flix"],
              bundleID: "com.netflix.Netflix"),

        Entry("disney_plus", "Disney+",     .stream,
              url: "https://www.disneyplus.com",
              aliases: ["disney plus", "disney+", "disneyplus", "disney"],
              bundleID: "com.disney.disneyplus"),

        Entry("apple_tv", "Apple TV",       .stream,
              url: "https://tv.apple.com",
              aliases: ["apple tv", "appletv", "apple television"],
              bundleID: "com.apple.tv"),

        Entry("spotify", "Spotify",         .stream,
              url: "https://www.spotify.com",
              aliases: ["spotify"],
              bundleID: "com.spotify.client"),

        Entry("twitch", "Twitch",           .stream,
              url: "https://www.twitch.tv",
              aliases: ["twitch", "twitch tv"],
              bundleID: "tv.twitch"),

        Entry("prime_video", "Prime Video", .stream,
              url: "https://www.primevideo.com",
              aliases: ["prime video", "amazon prime", "amazon prime video", "prime"],
              bundleID: "com.amazon.aiv.AIVApp"),

        Entry("hulu", "Hulu",               .stream,
              url: "https://www.hulu.com",
              aliases: ["hulu"],
              bundleID: "com.hulu.plus"),

        Entry("bbc_iplayer", "BBC iPlayer", .stream,
              url: "https://www.bbc.co.uk/iplayer",
              aliases: ["bbc iplayer", "iplayer", "bbc i player", "i player"]),

        Entry("channel4", "Channel 4",      .stream,
              url: "https://www.channel4.com",
              aliases: ["channel 4", "channel4", "c4", "all 4", "all4"]),

        Entry("itv", "ITVX",                .stream,
              url: "https://www.itv.com",
              aliases: ["itv", "itvx", "itv hub", "itv player"]),

        Entry("dazn", "DAZN",               .stream,
              url: "https://www.dazn.com",
              aliases: ["dazn", "da zn"]),

        Entry("peacock", "Peacock",         .stream,
              url: "https://www.peacocktv.com",
              aliases: ["peacock", "peacock tv", "nbc peacock"]),

        Entry("apple_music", "Apple Music", .stream,
              url: "https://music.apple.com",
              aliases: ["apple music"],
              bundleID: "com.apple.Music"),

        Entry("tidal", "Tidal",             .stream,
              url: "https://tidal.com",
              aliases: ["tidal", "jay z music", "tidal music"]),

        Entry("soundcloud", "SoundCloud",   .stream,
              url: "https://soundcloud.com",
              aliases: ["soundcloud", "sound cloud"]),
    ]

    // MARK: - Common Websites / Apps

    static let commonWebsites: [Entry] = [
        Entry("github", "GitHub",           .website,
              url: "https://github.com",
              aliases: ["github", "git hub"],
              bundleID: "com.github.GitHubDesktop"),

        Entry("reddit", "Reddit",           .website,
              url: "https://www.reddit.com",
              aliases: ["reddit", "red dit"],
              bundleID: "com.reddit.Reddit"),

        Entry("twitter", "X (Twitter)",     .website,
              url: "https://www.x.com",
              aliases: ["twitter", "x", "x twitter", "x dot com"]),

        Entry("linkedin", "LinkedIn",       .website,
              url: "https://www.linkedin.com",
              aliases: ["linkedin", "linked in"],
              bundleID: "com.linkedin.LinkedIn"),

        Entry("instagram", "Instagram",     .website,
              url: "https://www.instagram.com",
              aliases: ["instagram", "insta"],
              bundleID: "com.burbn.instagram"),

        Entry("google", "Google",           .website,
              url: "https://www.google.com",
              aliases: ["google", "google search"]),

        Entry("maps", "Apple Maps",         .app,
              url: "maps://",
              aliases: ["apple maps", "maps", "google maps"],
              bundleID: "com.apple.Maps"),

        Entry("shopify", "Shopify",         .website,
              url: "https://www.shopify.com",
              aliases: ["shopify"],
              bundleID: "com.jadedpixel.shopify"),
    ]

    // MARK: - All entries

    static var all: [Entry] {
        newsChannels + streamingServices + commonWebsites
    }
}
