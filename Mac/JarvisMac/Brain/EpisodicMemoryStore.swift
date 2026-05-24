import Foundation
import os

// MARK: - EpisodicMemoryEntry

/// A memory item that retains its episodic context — the session, app, and topic
/// it was formed during. This makes retrieval much richer than flat key-value memory.
struct EpisodicMemoryEntry: Identifiable, Codable {
    let id: String
    let text: String
    let title: String
    let type: MemoryCandidateType
    var importance: Double
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var resolvedAt: Date?

    // Episodic context
    var sessionId: String?
    var dominantApp: String?
    var topic: String?
    var projectName: String?
    var emotionalContext: String?

    var isResolved: Bool { resolvedAt != nil }
    var linkedMemoryIds: [String] = []

    var ageDays: Double {
        Date().timeIntervalSince(createdAt) / 86400
    }

    var relevanceScore: Double {
        let decay = max(0, 1.0 - ageDays / 60.0)
        return importance * confidence * decay
    }
}

// MARK: - EpisodicMemoryStore

/// Long-term episodic memory store. Sits alongside `BrainMemoryStore` but
/// preserves the *session context* in which memories were formed.
///
/// **Why separate from BrainMemoryStore?**
/// `BrainMemoryStore` stores flat facts. `EpisodicMemoryStore` stores facts
/// *with their story* — which app was open, what the conversation was about,
/// which session formed it. This enables temporal and project-scoped retrieval.
@MainActor
final class EpisodicMemoryStore {

    static let shared = EpisodicMemoryStore()

    private(set) var entries: [EpisodicMemoryEntry] = []
    private let maxEntries = 1000
    private let log = Logger(subsystem: "com.jarvis", category: "brain.episodic")

    // MARK: - Persistence

    private var fileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac")
        return support.appendingPathComponent("episodic_memory.json")
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([EpisodicMemoryEntry].self, from: data)
        else { return }
        entries = loaded
        log.debug("Loaded \(loaded.count) episodic entries")
    }

    private func saveToDisk() {
        let snapshot = entries
        Task.detached(priority: .utility) { [url = fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Write

    func register(
        text: String,
        title: String,
        type: MemoryCandidateType,
        importance: Double,
        confidence: Double,
        sessionId: String? = nil,
        dominantApp: String? = nil,
        topic: String? = nil,
        projectName: String? = nil,
        emotionalContext: String? = nil,
        linkedIds: [String] = []
    ) {
        // Quality gate: reject noise, false wakes, and weak chatter before storing
        let validation = MemoryValidationLayer.validate(
            text: text, title: title, type: type,
            importance: importance, confidence: confidence
        )
        guard validation.shouldStore else {
            log.debug("episodic_rejected reason=\(validation.reason) text=\(text.prefix(40))")
            return
        }
        if isDuplicate(text: text, project: projectName) { return }

        let entry = EpisodicMemoryEntry(
            id: UUID().uuidString,
            text: text,
            title: title,
            type: type,
            importance: importance,
            confidence: confidence,
            createdAt: Date(),
            updatedAt: Date(),
            sessionId: sessionId,
            dominantApp: dominantApp,
            topic: topic,
            projectName: projectName,
            emotionalContext: emotionalContext,
            linkedMemoryIds: linkedIds
        )
        entries.append(entry)
        enforceCap()
        saveToDisk()
    }

    func markResolved(_ id: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].resolvedAt = Date()
            entries[idx].updatedAt = Date()
            saveToDisk()
        }
    }

    func updateImportance(_ id: String, importance: Double) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].importance = importance
            entries[idx].updatedAt = Date()
            saveToDisk()
        }
    }

    // MARK: - Query

    func recent(limit: Int = 20) -> [EpisodicMemoryEntry] {
        Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func forProject(_ project: String, limit: Int = 20) -> [EpisodicMemoryEntry] {
        entries
            .filter { $0.projectName?.localizedCaseInsensitiveContains(project) == true }
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(limit)
            .map { $0 }
    }

    func unresolved(type: MemoryCandidateType? = nil) -> [EpisodicMemoryEntry] {
        entries
            .filter { !$0.isResolved && (type == nil || $0.type == type) }
            .sorted { $0.importance > $1.importance }
    }

    func search(query: String, limit: Int = 10) -> [EpisodicMemoryEntry] {
        let lower = query.lowercased()
        let words = lower.split(separator: " ").map(String.init).filter { $0.count > 3 }
        return entries
            .filter { entry in
                let t = (entry.text + " " + entry.title + " " + (entry.topic ?? "")).lowercased()
                return words.contains { t.contains($0) }
            }
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(limit)
            .map { $0 }
    }

    func contextForLLM(query: String, maxItems: Int = 4) -> String {
        let results = search(query: query, limit: maxItems)
        guard !results.isEmpty else { return "" }
        var lines = ["[EPISODIC MEMORY CONTEXT]"]
        for r in results {
            var line = "• \(r.title): \(r.text)"
            if let proj = r.projectName { line += " [project: \(proj)]" }
            if let app = r.dominantApp { line += " [in: \(app)]" }
            lines.append(line)
        }
        lines.append("(treat as supplemental episodic context, not ground truth)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Internal

    private func isDuplicate(text: String, project: String?) -> Bool {
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        return entries.contains { e in
            guard e.projectName == project else { return false }
            let eWords = Set(e.text.lowercased().split(separator: " ").map(String.init))
            let intersection = words.intersection(eWords)
            let union = words.union(eWords)
            return union.isEmpty ? false : Double(intersection.count) / Double(union.count) > 0.70
        }
    }

    private func enforceCap() {
        guard entries.count > maxEntries else { return }
        entries = entries
            .sorted { lhs, rhs in
                if lhs.isResolved != rhs.isResolved { return lhs.isResolved }
                return lhs.relevanceScore > rhs.relevanceScore
            }
            .prefix(maxEntries)
            .map { $0 }
    }
}
