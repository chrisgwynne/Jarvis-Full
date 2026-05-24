import Foundation

// MARK: - ConversationTurn

/// One complete voice-command exchange within a session.
struct ConversationTurn: Codable, Identifiable {
    var id:                        UUID   = UUID()
    var sessionId:                 String
    var timestamp:                 Date
    var transcript:                String
    var route:                     ConversationRoute
    var response:                  String?
    var memoryCandidatesExtracted: Int
}

// MARK: - ConversationMemoryStore

/// Persists conversation turns and extracted memory candidates across sessions.
///
/// Two JSON files under Application Support:
/// - `conversation_log.json`  — ring buffer of the last 200 turns.
/// - `project_memory.json`    — up to 500 extracted `MemoryCandidate` items.
///
/// All mutations are performed on the MainActor; background disk I/O is
/// dispatched to a private serial queue so the main thread is never blocked.
@MainActor
final class ConversationMemoryStore {

    static let shared = ConversationMemoryStore()

    // MARK: - Constants

    private static let maxTurns  = 200
    private static let maxMemory = 500

    // MARK: - Storage URLs

    private let logURL:    URL
    private let memoryURL: URL

    // MARK: - In-memory state

    private(set) var recentTurns: [ConversationTurn] = []
    private(set) var memoryItems: [MemoryCandidate]  = []

    // MARK: - Background I/O

    /// Serial queue for all disk writes so we never block the main thread.
    private let ioQueue = DispatchQueue(label: "com.jarvis.convmemory.io", qos: .utility)

    // MARK: - Init

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in:  .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL    = dir.appendingPathComponent("conversation_log.json")
        memoryURL = dir.appendingPathComponent("project_memory.json")
        load()
    }

    // MARK: - Turn logging

    /// Append a completed turn to the ring buffer and persist asynchronously.
    func logTurn(_ turn: ConversationTurn) {
        recentTurns.append(turn)
        if recentTurns.count > Self.maxTurns {
            recentTurns = Array(recentTurns.suffix(Self.maxTurns))
        }
        scheduleSave()
    }

    /// Return the `limit` most-recent turns, optionally filtered by session.
    func recentHistory(limit: Int = 5, sessionId: String? = nil) -> [ConversationTurn] {
        var turns = recentTurns
        if let sid = sessionId {
            turns = turns.filter { $0.sessionId == sid }
        }
        return Array(turns.suffix(limit))
    }

    /// Build a human-readable transcript block for LLM injection.
    ///
    /// Each turn is rendered as:
    /// ```
    /// User: <transcript>
    /// Jarvis: <response>   (when present)
    /// ---
    /// ```
    func formattedHistory(limit: Int = 4) -> String {
        recentHistory(limit: limit)
            .map { turn in
                var parts = ["User: \(turn.transcript)"]
                if let response = turn.response {
                    parts.append("Jarvis: \(response)")
                }
                return parts.joined(separator: "\n")
            }
            .joined(separator: "\n---\n")
    }

    // MARK: - Memory item management

    /// Persist a `MemoryCandidate` if it passes confidence and dedup checks.
    ///
    /// Items with type `.discard` or confidence below 0.60 are silently dropped.
    /// Items whose title or summary exactly matches an existing entry are dropped (exact dedup).
    /// Items whose combined title+summary shares >75% word overlap with an existing entry are
    /// also dropped (fuzzy Jaccard dedup — catches near-duplicate rephrasing of the same fact).
    func saveMemory(_ candidate: MemoryCandidate) {
        guard candidate.type != .discard, candidate.confidence >= 0.60 else { return }

        // Exact-match deduplication (kept as the fast first pass)
        let alreadyExists = memoryItems.contains { existing in
            existing.title.lowercased()   == candidate.title.lowercased() ||
            existing.summary.lowercased() == candidate.summary.lowercased()
        }
        guard !alreadyExists else { return }

        // Fuzzy deduplication — reject near-duplicate phrasings
        guard !isTooSimilarToExisting(candidate) else { return }

        memoryItems.append(candidate)

        if memoryItems.count > Self.maxMemory {
            // Prune: pinned memories are always retained; among the rest, prefer
            // highest confidence and break ties by most recent.
            let pinned   = memoryItems.filter  { $0.isPinned }
            let pruneable = memoryItems.filter { !$0.isPinned }
                .sorted { a, b in
                    let confDiff = a.confidence - b.confidence
                    if abs(confDiff) > 0.1 { return confDiff > 0 }
                    return a.createdAt > b.createdAt
                }
            let keepCount = max(0, Self.maxMemory - pinned.count)
            memoryItems = pinned + Array(pruneable.prefix(keepCount))
        }

        scheduleSave()
    }

    /// Returns true when the candidate's combined title+summary has >75% Jaccard
    /// word-overlap with any existing memory item — indicating a near-duplicate.
    ///
    /// Jaccard similarity = |intersection| / |union| over the word sets.
    /// 75% was chosen as the threshold: it rejects "Prefers dark mode" vs
    /// "User prefers dark mode" (high overlap) while allowing genuinely distinct
    /// facts that happen to share common words like "user" or "project".
    private func isTooSimilarToExisting(_ candidate: MemoryCandidate) -> Bool {
        let newText = (candidate.title + " " + candidate.summary).lowercased()
        let newWords = Set(newText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty })
        guard !newWords.isEmpty else { return false }

        return memoryItems.contains { existing in
            let existingText = (existing.title + " " + existing.summary).lowercased()
            let existingWords = Set(existingText.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty })
            guard !existingWords.isEmpty else { return false }
            let intersection = newWords.intersection(existingWords).count
            let union = newWords.union(existingWords).count
            return Double(intersection) / Double(union) > 0.75
        }
    }

    // MARK: - Pinning

    /// Pin a memory by ID so it is excluded from automatic pruning.
    func pin(id: UUID) {
        guard let idx = memoryItems.firstIndex(where: { $0.id == id }) else { return }
        memoryItems[idx].isPinned = true
        scheduleSave()
    }

    /// Unpin a memory, restoring it to normal pruning eligibility.
    func unpin(id: UUID) {
        guard let idx = memoryItems.firstIndex(where: { $0.id == id }) else { return }
        memoryItems[idx].isPinned = false
        scheduleSave()
    }

    /// Keyword search across title, summary, and tags.
    ///
    /// Results are sorted by the number of matched terms (descending).
    func search(query: String, limit: Int = 10) async -> [MemoryCandidate] {
        let terms = query.lowercased()
            .components(separatedBy: " ")
            .filter { $0.count > 2 }

        guard !terms.isEmpty else {
            return Array(memoryItems.suffix(limit))
        }

        let scored: [(MemoryCandidate, Int)] = memoryItems.compactMap { item in
            let searchable = (item.title + " " + item.summary + " " + item.tags.joined(separator: " ")).lowercased()
            let score = terms.filter { searchable.contains($0) }.count
            return score > 0 ? (item, score) : nil
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Return the most-recent `limit` items of a specific type.
    func recentByType(_ type: MemoryCandidateType, limit: Int = 5) -> [MemoryCandidate] {
        memoryItems
            .filter    { $0.type == type }
            .sorted    { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map       { $0 }
    }

    /// Permanently remove a memory item by ID.
    func deleteMemory(id: UUID) {
        memoryItems.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Summary

    /// A one-line summary of today's activity, suitable for a status bar tooltip
    /// or spoken briefing fragment.
    func todaysSummary() -> String {
        let calendar    = Calendar.current
        let todayTurns  = recentTurns.filter  { calendar.isDateInToday($0.timestamp) }
        let todayItems  = memoryItems.filter   { calendar.isDateInToday($0.createdAt) }

        var parts: [String] = []

        if !todayTurns.isEmpty {
            parts.append("\(todayTurns.count) conversation turn\(todayTurns.count == 1 ? "" : "s") today")
        }

        if !todayItems.isEmpty {
            let grouped = Dictionary(grouping: todayItems, by: { $0.type.rawValue })
            let typesSummary = grouped
                .map { "\($0.value.count) \($0.key)" }
                .joined(separator: ", ")
            parts.append("Logged: \(typesSummary)")
        }

        return parts.isEmpty ? "No activity logged today" : parts.joined(separator: ". ")
    }

    // MARK: - Persistence

    private func load() {
        let decoder                   = JSONDecoder()
        decoder.dateDecodingStrategy  = .iso8601

        if let data  = try? Data(contentsOf: logURL),
           let turns = try? decoder.decode([ConversationTurn].self, from: data) {
            recentTurns = turns
        }

        if let data  = try? Data(contentsOf: memoryURL),
           let items = try? decoder.decode([MemoryCandidate].self, from: data) {
            memoryItems = items
        }
    }

    /// Capture snapshots on the MainActor, then write on the background queue.
    private func scheduleSave() {
        let turnSnapshot   = recentTurns
        let memorySnapshot = memoryItems
        let logDest        = logURL
        let memDest        = memoryURL

        ioQueue.async {
            let encoder                   = JSONEncoder()
            encoder.dateEncodingStrategy  = .iso8601
            encoder.outputFormatting      = .prettyPrinted

            if let data = try? encoder.encode(turnSnapshot) {
                try? data.write(to: logDest, options: .atomic)
            }
            if let data = try? encoder.encode(memorySnapshot) {
                try? data.write(to: memDest, options: .atomic)
            }
        }
    }
}
