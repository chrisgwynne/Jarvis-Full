import Foundation
import os

// MARK: - BrainMemoryStore

/// The authoritative durable long-term memory layer.
///
/// **Ownership model**
/// - `ConversationMemoryStore` — short-term conversational staging (200 turns, 500 candidates)
/// - `MemoryStore`             — explicit user "remember this" entries
/// - `BrainMemoryStore`        — committed, searchable, governed long-term intelligence
///
/// A `MemoryCandidate` is staged in `ConversationMemoryStore` until its confidence and
/// importance clear the governance threshold, then committed here via `commit(_:)`.
///
/// **Memory lifecycle**
/// ```
/// RAW EVENT → MemoryExtractor → MemoryCandidate (staged) →
/// importance/confidence scoring → commit(_:) →
/// BrainMemoryStore (SQLite) + SemanticMemoryIndex + EntityGraph linking →
/// EpisodeStore grouping → dream-cycle consolidation
/// ```
@MainActor
final class BrainMemoryStore {

    static let shared = BrainMemoryStore()

    // MARK: - Dependencies (set by BrainRuntime.start())

    private var db: JarvisDatabase?
    private var semanticIndex: SemanticMemoryIndex?

    // MARK: - In-memory cache

    private(set) var memories: [MemoryCandidate] = []
    private let maxInMemory = 500
    private let log = Logger(subsystem: "com.jarvis", category: "brain.memory")

    // MARK: - Governance thresholds

    /// Minimum combined score (confidence × importance) required for auto-commit.
    static let autoCommitThreshold: Double = 0.49   // e.g. conf 0.7 × imp 0.7

    // MARK: - Configuration

    func configure(db: JarvisDatabase, semanticIndex: SemanticMemoryIndex) {
        self.db = db
        self.semanticIndex = semanticIndex
        loadFromDisk()
        Task.detached(priority: .utility) { [weak self] in
            await self?.sweepExpired()
        }
    }

    // MARK: - Commit

    /// Commit a `MemoryCandidate` to durable storage.
    ///
    /// - Skips `.discard` type and private-policy entries with low importance.
    /// - Deduplicates using title-match and 75% Jaccard word-overlap.
    /// - Adds to in-memory cache, SQLite, and semantic index.
    @discardableResult
    func commit(_ candidate: MemoryCandidate) async -> Bool {
        guard candidate.type != .discard else { return false }
        // Private memories are only stored locally if explicitly user-created.
        if candidate.privacyLevel == .private {
            guard candidate.source == .voiceCommand || candidate.source == .userEdited else { return false }
        }

        // Deduplication — same title or >75% Jaccard overlap
        if memories.contains(where: { isDuplicate($0, candidate) }) {
            log.debug("brain.memory: skipping duplicate — \(candidate.title.prefix(60))")
            return false
        }

        var committed = candidate
        committed.updatedAt = Date()

        // Append to cache (bounded)
        memories.append(committed)
        if memories.count > maxInMemory {
            let pinned   = memories.filter  { $0.isPinned }
            let pruneable = memories.filter { !$0.isPinned }
                .sorted { $0.importance > $1.importance }
            let keep = max(0, maxInMemory - pinned.count)
            memories = pinned + Array(pruneable.prefix(keep))
        }

        // SQLite write
        persistToDisk(committed)

        // Semantic index (skip private/sensitive)
        if candidate.privacyLevel == .normal, let idx = semanticIndex {
            let searchText = "\(committed.title) \(committed.summary)"
            idx.index(id: committed.id.uuidString, text: searchText)
        }

        // Publish event
        SystemBus.shared.publish(BrainMemoryWrittenEvent(
            memoryId:     committed.id.uuidString,
            memoryType:   committed.type.rawValue,
            memorySource: committed.source.rawValue
        ))

        log.info("brain.memory: committed [\(committed.type.rawValue)] \(committed.title.prefix(60))")
        return true
    }

    // MARK: - Search

    /// Hybrid FTS5 + semantic search across committed memories.
    ///
    /// Privacy-level filtering: `.private` entries are excluded from search results.
    func search(query: String, limit: Int = 20) async -> [MemoryCandidate] {
        let terms = ftsTerms(query)
        guard !terms.isEmpty else {
            return recentVisible(limit: limit)
        }

        var idSet   = Set<String>()
        var results: [MemoryCandidate] = []

        // 1. FTS keyword hits
        if let db {
            let rows = (try? db.searchBrainMemories(query: terms, limit: limit)) ?? []
            for row in rows {
                if let m = toCandidate(row), !idSet.contains(m.id.uuidString) {
                    idSet.insert(m.id.uuidString)
                    results.append(m)
                }
            }
        }

        // 2. Semantic hits
        if let idx = semanticIndex {
            let hits = idx.search(query: query, limit: limit)
            for hit in hits {
                if !idSet.contains(hit.id),
                   let m = memories.first(where: { $0.id.uuidString == hit.id }) {
                    idSet.insert(hit.id)
                    results.append(m)
                }
            }
        }

        // 3. Remove private, sort by importance × recency
        return results
            .filter { $0.privacyLevel != .private }
            .sorted { score($0) > score($1) }
            .prefix(limit)
            .map { $0 }
    }

    /// Retrieve committed memories by type, sorted by importance desc.
    func byType(_ type: MemoryCandidateType, limit: Int = 10) async -> [MemoryCandidate] {
        if let db {
            let rows = (try? db.brainMemoriesByType(type.rawValue, limit: limit)) ?? []
            return rows.compactMap { toCandidate($0) }
                .filter { $0.privacyLevel != .private }
        }
        return memories
            .filter { $0.type == type && $0.privacyLevel != .private }
            .sorted { $0.importance > $1.importance }
            .prefix(limit)
            .map { $0 }
    }

    /// N most-recent non-private memories.
    func recent(limit: Int = 20) -> [MemoryCandidate] {
        recentVisible(limit: limit)
    }

    // MARK: - Mutation

    func delete(id: UUID) async {
        memories.removeAll { $0.id == id }
        if let db { try? db.deleteBrainMemory(id: id.uuidString) }
        log.info("brain.memory: deleted \(id.uuidString.prefix(8))")
    }

    func update(_ memory: MemoryCandidate) async {
        if let idx = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[idx] = memory
        }
        persistToDisk(memory)
    }

    func pin(_ id: UUID, pinned: Bool) async {
        if let idx = memories.firstIndex(where: { $0.id == id }) {
            memories[idx].isPinned = pinned
            persistToDisk(memories[idx])
        }
    }

    // MARK: - Maintenance

    /// Remove entries whose `expiresAt` has passed.
    func sweepExpired() async {
        let now = Date()
        let before = memories.count
        memories.removeAll { mem in
            guard let exp = mem.expiresAt else { return false }
            return exp < now
        }
        if memories.count < before {
            log.info("brain.memory: swept \(before - self.memories.count) expired entries")
        }
        if let db { try? db.sweepExpiredBrainMemories() }
    }

    // MARK: - LLM context

    /// Build a `[BRAIN MEMORY CONTEXT]` block for LLM injection.
    /// Skips `.sensitive` and `.private` entries.
    func contextForLLM(query: String, maxItems: Int = 5) async -> String {
        let hits = await search(query: query, limit: maxItems)
        let visible = hits.filter { $0.privacyLevel == .normal }
        guard !visible.isEmpty else { return "" }

        let lines = visible.map { m -> String in
            "[\(m.type.rawValue)] \(m.title): \(m.summary)"
        }.joined(separator: "\n")

        return """
        [BRAIN MEMORY CONTEXT]
        \(lines)
        [END BRAIN MEMORY CONTEXT]
        """
    }

    // MARK: - Private helpers

    private func loadFromDisk() {
        guard let db else { return }
        let rows = (try? db.recentBrainMemories(limit: maxInMemory)) ?? []
        memories = rows.compactMap { toCandidate($0) }
        log.info("brain.memory: loaded \(self.memories.count) entries")
    }

    private func persistToDisk(_ candidate: MemoryCandidate) {
        guard let db else { return }
        let tagsJSON       = jsonArray(candidate.tags)
        let entityIdsJSON  = jsonArray(candidate.linkedEntityIds)
        try? db.insertBrainMemory(
            id:             candidate.id.uuidString,
            type:           candidate.type.rawValue,
            tier:           candidate.tier.rawValue,
            title:          candidate.title,
            summary:        candidate.summary,
            rawText:        candidate.rawText,
            source:         candidate.source.rawValue,
            confidence:     candidate.confidence,
            importance:     candidate.importance,
            createdAt:      candidate.createdAt,
            updatedAt:      candidate.updatedAt,
            expiresAt:      candidate.expiresAt,
            tagsJSON:       tagsJSON,
            entityIdsJSON:  entityIdsJSON,
            conversationId: candidate.originalConversationId,
            privacyLevel:   candidate.privacyLevel.rawValue,
            isPinned:       candidate.isPinned
        )
    }

    private func toCandidate(_ row: BrainMemoryRow) -> MemoryCandidate? {
        guard let type = MemoryCandidateType(rawValue: row.type),
              let tier = MemoryTier(rawValue: row.tier)
        else { return nil }

        var m = MemoryCandidate(
            type:       type,
            tier:       tier,
            title:      row.title,
            summary:    row.summary,
            rawText:    row.rawText,
            confidence: row.confidence,
            tags:       parseJSONArray(row.tagsJSON),
            createdAt:  row.createdAt
        )
        m.id                   = UUID(uuidString: row.id) ?? UUID()
        m.importance           = row.importance
        m.updatedAt            = row.updatedAt
        m.expiresAt            = row.expiresAt
        m.source               = BrainMemorySource(rawValue: row.source) ?? .memoryExtractor
        m.linkedEntityIds      = parseJSONArray(row.entityIdsJSON)
        m.originalConversationId = row.conversationId
        m.privacyLevel         = BrainPrivacyLevel(rawValue: row.privacyLevel) ?? .normal
        m.isPinned             = row.isPinned
        return m
    }

    private func recentVisible(limit: Int) -> [MemoryCandidate] {
        memories
            .filter { $0.privacyLevel != .private }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    private func score(_ m: MemoryCandidate) -> Double {
        let ageDays = Date().timeIntervalSince(m.createdAt) / 86400
        let decay   = max(0.1, 1.0 - ageDays / 60)  // 60-day half-life
        return m.importance * m.confidence * decay
    }

    private func isDuplicate(_ a: MemoryCandidate, _ b: MemoryCandidate) -> Bool {
        if a.title.lowercased() == b.title.lowercased() { return true }
        let wa = wordSet(a.title + " " + a.summary)
        let wb = wordSet(b.title + " " + b.summary)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let intersection = wa.intersection(wb).count
        let union        = wa.union(wb).count
        return Double(intersection) / Double(union) > 0.75
    }

    private func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 })
    }

    private func ftsTerms(_ query: String) -> String {
        query.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private func jsonArray(_ arr: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: arr), encoding: .utf8)) ?? "[]"
    }

    private func parseJSONArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
