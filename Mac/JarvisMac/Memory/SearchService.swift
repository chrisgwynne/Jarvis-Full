import Foundation
import os

// MARK: - Result types

enum SearchResultKind: String {
    case conversation
    case memory
    case snapshot
}

struct SearchResult: Identifiable {
    let id: String
    let kind: SearchResultKind
    let ts: Date
    let text: String
    let snippet: String  // truncated for display
    let role: String?    // conversations only: "user" | "assistant"
}

// MARK: - Service

/// Fans out a query to all FTS-indexed stores and merges the results,
/// sorted by timestamp descending. All work happens on a private queue.
final class SearchService {

    private let convStore: ConversationStore
    private let memStore: MemoryStore
    let snapshotStore: ContextSnapshotStore?

    /// Optional semantic index — wired in from JarvisController after init.
    var semanticIndex: SemanticMemoryIndex?

    init(convStore: ConversationStore, memStore: MemoryStore,
         snapshotStore: ContextSnapshotStore? = nil) {
        self.convStore = convStore
        self.memStore = memStore
        self.snapshotStore = snapshotStore
    }

    /// Search conversations and memories; returns up to `limit` merged results.
    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        async let convResults = convStore.search(query: query, limit: limit)
        async let memResults  = memStore.search(query: query, limit: limit)

        let (convRows, memRows) = await (convResults, memResults)

        var out: [SearchResult] = []
        for row in convRows {
            out.append(SearchResult(
                id: "conv-\(row.id)",
                kind: .conversation,
                ts: row.ts,
                text: row.text,
                snippet: snippet(row.text),
                role: row.role
            ))
        }
        for row in memRows {
            out.append(SearchResult(
                id: "mem-\(row.id)",
                kind: .memory,
                ts: row.ts,
                text: row.text,
                snippet: snippet(row.text),
                role: nil
            ))
        }

        return out
            .sorted { $0.ts > $1.ts }
            .prefix(limit)
            .map { $0 }
    }

    /// Summarise recent memories as a short bulleted string for TTS.
    func memorySummary(limit: Int = 5) async -> String {
        let rows = await memStore.all(limit: limit)
        guard !rows.isEmpty else { return "I don't have anything stored in memory yet." }
        let bullets = rows.map { "• \($0.text)" }.joined(separator: "\n")
        return "Here's what I remember:\n\(bullets)"
    }

    /// Recent activity summary for "what was I doing earlier" — combines
    /// recent conversations and snapshots into a timeline for TTS.
    func recentActivitySummary(limit: Int = 5) async -> String {
        if let store = snapshotStore {
            return await store.activitySummary(limit: limit)
        }
        // Fallback: use recent conversations if no snapshot store.
        let rows = await convStore.recent(limit: limit * 2)
        guard !rows.isEmpty else { return "I don't have any recent activity recorded yet." }
        let assistantRows = rows.filter { $0.role == "assistant" }.prefix(limit)
        guard !assistantRows.isEmpty else { return "I don't have any recent responses recorded yet." }
        let lines = assistantRows.map { row in
            let ago = ContextSnapshotStore.relativeTime(row.ts)
            return "\(ago): \(row.text.prefix(80))"
        }
        return "Here's what I've been up to:\n" + lines.joined(separator: "\n")
    }

    /// Recent conversations for overlay display.
    func recentConversations(limit: Int = 20) async -> [ConversationRow] {
        await convStore.recent(limit: limit)
    }

    // MARK: - Semantic search

    /// Semantic search — returns entries by meaning, not keyword.
    /// Returns empty if the semantic index is not available.
    @MainActor
    func semanticSearch(query: String, limit: Int = 5) -> [SearchResult] {
        guard let index = semanticIndex else { return [] }
        let entries = index.search(query: query, limit: limit)
        return entries.map { entry in
            SearchResult(
                id: "semantic-\(entry.id)",
                kind: .memory,
                ts: entry.addedAt,
                text: entry.text,
                snippet: snippet(entry.text),
                role: nil
            )
        }
    }

    /// Combined keyword + semantic + Brain search, deduplicated by text content prefix.
    /// Brain results are appended after keyword/semantic results; importance × confidence
    /// ranking is preserved from BrainMemoryStore.search().
    /// Falls back gracefully if Brain or semantic indexes are unavailable.
    @MainActor
    func hybridSearch(query: String, limit: Int = 10) async -> [SearchResult] {
        let kwResults     = await search(query: query, limit: limit)
        let semResults    = semanticSearch(query: query, limit: max(2, limit / 2))
        let brainCandidates = await BrainMemoryStore.shared.search(query: query, limit: max(3, limit / 3))

        var seen = Set<String>()
        var out: [SearchResult] = []

        for r in kwResults + semResults {
            let key = String(r.text.prefix(60))
            if seen.insert(key).inserted { out.append(r) }
        }

        for candidate in brainCandidates {
            let text = "\(candidate.title): \(candidate.summary)"
            let key  = String(text.prefix(60))
            if seen.insert(key).inserted {
                out.append(SearchResult(
                    id:      "brain-\(candidate.id.uuidString)",
                    kind:    .memory,
                    ts:      candidate.updatedAt,
                    text:    text,
                    snippet: snippet(text),
                    role:    nil
                ))
            }
        }

        return Array(out.prefix(limit))
    }

    // MARK: - Private

    private func snippet(_ text: String, maxLen: Int = 80) -> String {
        text.count <= maxLen ? text : String(text.prefix(maxLen)) + "…"
    }
}
