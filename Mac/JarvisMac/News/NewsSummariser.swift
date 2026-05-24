import Foundation

/// Builds a spoken/display summary from article metadata.
/// Pure function — no ML, no network.
enum NewsSummariser {

    /// Short spoken summary for TTS (≤ 2 sentences).
    static func spokenSummary(article: NewsArticle) -> String {
        let source = article.sourceName.isEmpty ? "a source" : article.sourceName
        let timeAgo = relativeTime(article.publishedAt)
        let desc = article.contentExcerpt.isEmpty ? article.summary : article.contentExcerpt
        let trimmedDesc = truncate(desc, to: 160)
        if trimmedDesc.isEmpty {
            return "\(article.title), from \(source), \(timeAgo)."
        }
        return "\(article.title), from \(source), \(timeAgo). \(trimmedDesc)"
    }

    /// One-line display summary (used in overlay cards and context snapshots).
    static func briefSummary(article: NewsArticle) -> String {
        if !article.summary.isEmpty { return truncate(article.summary, to: 120) }
        if !article.contentExcerpt.isEmpty { return truncate(article.contentExcerpt, to: 120) }
        return article.title
    }

    /// Multi-article digest for "summarise the news" command.
    /// Returns a natural-language spoken paragraph.
    static func digestSummary(articles: [NewsArticle], label: NewsLabel? = nil) -> String {
        let filtered = label == nil ? articles : articles.filter { $0.labels.contains(label!) }
        let top = Array(filtered.prefix(5))
        guard !top.isEmpty else {
            return label != nil ? "I don't have any \(label!.displayName) stories right now."
                                : "I don't have any news right now. Try refreshing the feeds."
        }

        let labelDesc = label?.displayName ?? "top"
        var parts: [String] = ["Here are the \(labelDesc) headlines."]

        for (i, a) in top.enumerated() {
            let prefix = i == 0 ? "First" : i == top.count - 1 ? "And finally" : ordinal(i + 1)
            parts.append("\(prefix): \(a.title), from \(a.sourceName).")
        }

        return parts.joined(separator: " ")
    }

    /// Short natural-language description for "what did I do today" context inclusion.
    static func headlinesList(articles: [NewsArticle], maxItems: Int = 3) -> String {
        let top = Array(articles.prefix(maxItems))
        return top.map { "• \($0.title)" }.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func truncate(_ s: String, to length: Int) -> String {
        guard length > 0 else { return "" }
        guard s.count > length else { return s }
        return s.safelyTruncated(to: length).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(seconds / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 2: return "Second"
        case 3: return "Third"
        case 4: return "Fourth"
        case 5: return "Fifth"
        default: return "\(n)th"
        }
    }
}
