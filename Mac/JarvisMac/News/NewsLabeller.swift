import Foundation

/// Pure-function deterministic labeller.
/// No ML — keyword rules + feed-hint seeds.
enum NewsLabeller {

    // MARK: - Keyword rules

    private static let keywordRules: [(keywords: [String], label: NewsLabel)] = [
        // AI must come before technology to catch overlapping terms
        (["artificial intelligence", "machine learning", "openai", "chatgpt", "gemini", "llm",
          "large language model", "deep learning", "neural network", "claude", "mistral",
          "stable diffusion", "generative ai", "foundation model"], .ai),

        (["startup", "venture capital", "seed round", "series a", "series b", "ipo",
          "founder", "unicorn", "y combinator", "techcrunch"], .startups),

        (["iphone", "apple", "google", "microsoft", "amazon", "meta", "software", "app",
          "smartphone", "android", "developer", "coding", "programming", "chip", "semiconductor",
          "cybersecurity", "hack", "data breach", "tech"], .technology),

        (["design", "figma", "ux", "ui design", "typography", "brand", "logo", "creative"], .design),

        (["climate", "emissions", "carbon", "renewable", "solar", "wind energy", "electric vehicle",
          "biodiversity", "wildlife", "pollution", "deforestation"], .environment),

        (["parliament", "senate", "congress", "government", "election", "vote", "prime minister",
          "president", "minister", "labour", "conservative", "republican", "democrat",
          "policy", "legislation", "referendum"], .politics),

        (["stock", "shares", "market", "nasdaq", "s&p", "ftse", "bond", "interest rate",
          "inflation", "central bank", "gdp", "recession", "dow jones", "hedge fund",
          "cryptocurrency", "bitcoin", "ethereum"], .finance),

        (["economy", "trade", "merger", "acquisition", "profit", "revenue", "earnings",
          "ceo", "exec", "corporate", "company", "industry"], .business),

        (["nhs", "hospital", "vaccine", "cancer", "drug", "pandemic", "mental health",
          "research study", "clinical trial", "surgery", "medicine"], .health),

        (["film", "movie", "music", "celebrity", "streaming", "netflix", "spotify", "award",
          "album", "concert", "tv show", "series", "trailer"], .entertainment),

        (["football", "soccer", "premier league", "nba", "nfl", "wimbledon", "cricket",
          "rugby", "formula 1", "f1", "olympics", "sport"], .sports),

        (["science", "space", "nasa", "quantum", "physics", "biology", "chemistry",
          "astronomy", "discovery", "experiment"], .science),

        (["wales", "cardiff", "swansea", "newport", "welsh"], .uk),

        (["uk", "britain", "england", "scotland", "northern ireland", "london", "boris",
          "sunak", "keir starmer", "nhs"], .uk),

        (["us news", "america", "washington", "white house", "china", "russia", "europe",
          "global", "international", "war", "conflict", "nato"], .world),
    ]

    // MARK: - Public API

    /// Assign labels to an article given its title, description, and optional feed hints.
    static func label(
        title: String,
        description: String,
        feedHints: [NewsLabel] = []
    ) -> [NewsLabel] {
        let combined = (title + " " + description).lowercased()
        var found = Set(feedHints)

        for rule in keywordRules {
            for keyword in rule.keywords {
                if combined.contains(keyword) {
                    found.insert(rule.label)
                    break
                }
            }
        }

        if found.isEmpty { found.insert(.other) }
        return Array(found).sorted { $0.rawValue < $1.rawValue }
    }

    /// Simple importance score in [0,1].
    /// Higher-signal labels (AI, technology, finance) boost score.
    static func importanceScore(labels: [NewsLabel], title: String) -> Double {
        let highSignal: Set<NewsLabel> = [.ai, .technology, .finance, .topStories]
        let base = 0.4
        let labelBoost = Double(labels.filter { highSignal.contains($0) }.count) * 0.12
        // Title in all caps or ending with "?" signal prominence
        let titleBoost: Double = title.filter(\.isUppercase).count > title.count / 2 ? 0.05 : 0
        // Breaking news indicator
        let breakingBoost: Double = isBreaking(title: title) ? 0.25 : 0
        return min(1.0, base + labelBoost + titleBoost + breakingBoost)
    }

    // MARK: - Breaking news detection

    /// Configured terms that indicate a breaking / urgent story.
    static let breakingTerms: [String] = [
        "breaking", "breaking news", "just in", "alert",
        "urgent", "developing", "live updates", "emergency",
        "shock", "exclusive", "confirmed:", "update:",
    ]

    /// Returns true if the title contains signals of a breaking or urgent story.
    static func isBreaking(title: String) -> Bool {
        let lower = title.lowercased()
        return breakingTerms.contains { lower.contains($0) }
    }

    /// Returns true if the article category string indicates breaking content.
    static func categoryIsBreaking(_ category: String) -> Bool {
        let lower = category.lowercased()
        return lower.contains("breaking") || lower.contains("alert") || lower.contains("urgent")
    }
}
