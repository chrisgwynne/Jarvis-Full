import Foundation

// MARK: - RetrievalMode

enum RetrievalMode {
    case semantic(query: String)
    case timeline(since: Date, until: Date?)
    case projectScoped(project: String)
    case unresolved(type: MemoryCandidateType?)
    case composite(query: String, project: String?)
}

// MARK: - RetrievalResult

struct RetrievalResult {
    let entry: EpisodicMemoryEntry
    let score: Double
    let matchReason: String
}

// MARK: - EpisodicMemoryRetriever

/// Multi-modal retriever for `EpisodicMemoryStore`.
///
/// Supports semantic keyword matching, timeline scoping, project filtering,
/// and unresolved-item retrieval. Results are scored and deduplicated.
///
/// Intentionally synchronous — no async — so it can be called inline in the
/// intent pipeline. Heavy semantic search is handled by `BrainMemoryStore`.
@MainActor
final class EpisodicMemoryRetriever {

    static let shared = EpisodicMemoryRetriever()

    private let store = EpisodicMemoryStore.shared

    // MARK: - Retrieval

    func retrieve(_ mode: RetrievalMode, limit: Int = 8) -> [RetrievalResult] {
        switch mode {
        case .semantic(let query):
            return semanticSearch(query: query, limit: limit)
        case .timeline(let since, let until):
            return timelineSearch(since: since, until: until, limit: limit)
        case .projectScoped(let project):
            return projectSearch(project: project, limit: limit)
        case .unresolved(let type):
            return unresolvedSearch(type: type, limit: limit)
        case .composite(let query, let project):
            return compositeSearch(query: query, project: project, limit: limit)
        }
    }

    func contextBlock(for mode: RetrievalMode, limit: Int = 4) -> String {
        let results = retrieve(mode, limit: limit)
        guard !results.isEmpty else { return "" }
        var lines = ["[EPISODIC RETRIEVAL]"]
        for r in results.prefix(limit) {
            var line = "• \(r.entry.title): \(r.entry.text)"
            if let proj = r.entry.projectName { line += " [\(proj)]" }
            line += " (\(r.matchReason))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Search modes

    private func semanticSearch(query: String, limit: Int) -> [RetrievalResult] {
        let lower = query.lowercased()
        let queryWords = Set(lower.split(separator: " ").map(String.init).filter { $0.count > 3 })
        guard !queryWords.isEmpty else { return [] }

        return store.entries
            .compactMap { entry -> RetrievalResult? in
                let entryText = (entry.text + " " + entry.title + " " + (entry.topic ?? "")).lowercased()
                let entryWords = Set(entryText.split(separator: " ").map(String.init))
                let matches = queryWords.intersection(entryWords)
                guard !matches.isEmpty else { return nil }
                let keywordScore = Double(matches.count) / Double(queryWords.count)
                let score = keywordScore * 0.6 + entry.relevanceScore * 0.4
                return RetrievalResult(
                    entry: entry,
                    score: score,
                    matchReason: "keyword: \(matches.prefix(3).joined(separator: ","))"
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func timelineSearch(since: Date, until: Date?, limit: Int) -> [RetrievalResult] {
        let end = until ?? Date()
        return store.entries
            .filter { $0.createdAt >= since && $0.createdAt <= end }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { RetrievalResult(entry: $0, score: $0.relevanceScore, matchReason: "timeline") }
    }

    private func projectSearch(project: String, limit: Int) -> [RetrievalResult] {
        store.forProject(project, limit: limit).map { entry in
            RetrievalResult(entry: entry, score: entry.relevanceScore, matchReason: "project: \(project)")
        }
    }

    private func unresolvedSearch(type: MemoryCandidateType?, limit: Int) -> [RetrievalResult] {
        store.unresolved(type: type)
            .prefix(limit)
            .map { RetrievalResult(entry: $0, score: $0.importance, matchReason: "unresolved") }
    }

    private func compositeSearch(query: String, project: String?, limit: Int) -> [RetrievalResult] {
        var candidates: [RetrievalResult]
        if let project {
            candidates = projectSearch(project: project, limit: limit * 2)
            let semanticIds = Set(semanticSearch(query: query, limit: limit * 2).map { $0.entry.id })
            candidates = candidates.map { r in
                if semanticIds.contains(r.entry.id) {
                    return RetrievalResult(entry: r.entry, score: r.score * 1.3, matchReason: "project+semantic")
                }
                return r
            }
        } else {
            candidates = semanticSearch(query: query, limit: limit)
        }
        return Array(candidates.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Convenience

    func recentUnresolved(limit: Int = 5) -> [EpisodicMemoryEntry] {
        retrieve(.unresolved(type: nil), limit: limit).map { $0.entry }
    }

    func forCurrentProject(limit: Int = 6) -> [EpisodicMemoryEntry] {
        let project = AmbientWorldState.shared.activeProject
        guard let project else { return store.recent(limit: limit) }
        return retrieve(.projectScoped(project: project), limit: limit).map { $0.entry }
    }
}
