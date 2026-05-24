import Foundation
import os
import NaturalLanguage

// MARK: - Embedding protocol (swap in CoreML model later)

protocol TextEmbedder {
    /// Returns a vector of fixed dimensionality for the given text.
    func embed(_ text: String) -> [Float]
    var dimension: Int { get }
}

// MARK: - NLEmbedding-based embedder (built-in, no model download needed)

final class NLTextEmbedder: TextEmbedder {
    private let sentenceEmbedding: NLEmbedding?
    private let wordEmbedding: NLEmbedding?
    let dimension: Int

    init() {
        let sent = NLEmbedding.sentenceEmbedding(for: .english)
        let word = NLEmbedding.wordEmbedding(for: .english)
        self.sentenceEmbedding = sent
        self.wordEmbedding = word
        // Prefer sentence embedding dimension; fall back to word or fixed 64
        self.dimension = sent?.dimension ?? word?.dimension ?? 64
    }

    func embed(_ text: String) -> [Float] {
        let input = String(text.lowercased().prefix(300))

        // Try sentence embedding first (most accurate for short texts)
        if let emb = sentenceEmbedding,
           let vec = emb.vector(for: input) {
            return vec.map { Float($0) }
        }

        // Fall back to averaging word vectors
        if let emb = wordEmbedding {
            let tokens = input
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
            var sum = [Float](repeating: 0, count: dimension)
            var count = 0
            for token in tokens.prefix(50) {
                if let vec = emb.vector(for: token) {
                    let len = min(vec.count, dimension)
                    for i in 0..<len { sum[i] += Float(vec[i]) }
                    count += 1
                }
            }
            if count > 0 {
                for i in 0..<dimension { sum[i] /= Float(count) }
                return sum
            }
        }

        // Final fallback: hash-based pseudo-embedding
        return bagOfWords(input)
    }

    private func bagOfWords(_ text: String) -> [Float] {
        var vec = [Float](repeating: 0, count: dimension > 0 ? dimension : 64)
        let dim = vec.count
        for (i, scalar) in text.unicodeScalars.enumerated() {
            vec[i % dim] += Float(scalar.value % 128) / 128.0
        }
        return vec
    }
}

// MARK: - Indexed entry

struct SemanticEntry: Codable {
    let id: String          // e.g. "mem-42" or "conv-17"
    let text: String
    let embedding: [Float]
    let addedAt: Date
}

// MARK: - Cosine similarity

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, normA: Float = 0, normB: Float = 0
    for i in 0..<a.count {
        dot   += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    let denom = sqrt(normA) * sqrt(normB)
    return denom > 0 ? dot / denom : 0
}

// MARK: - Index

/// In-memory semantic index that persists embeddings to disk as JSON.
/// Uses NLEmbedding (ships with macOS, no download needed) as the base embedder.
/// Designed to be used from the MainActor; all methods are synchronous
/// except the nonisolated persist helper.
@MainActor
final class SemanticMemoryIndex {

    /// nil until the background warm-up task finishes (typically 1-3s after init).
    /// index/search degrade gracefully while nil; pending items are flushed on ready.
    private var embedder: TextEmbedder?
    /// Items queued while the embedder is warming up, processed in flushPending().
    private var pendingItems: [(id: String, text: String)] = []
    private var entries: [SemanticEntry] = []
    private let fileURL: URL
    private let log = Logger(subsystem: "com.jarvis", category: "semantic")
    private let maxEntries = 500

    // Was 0.25 — raised to 0.45 to reduce noise in semantic recall.
    // At 0.45, only meaningfully related content surfaces; at 0.25 loosely
    // related content pollutes results.
    private let defaultSimilarityThreshold: Float = 0.45

    init(filename: String = "semantic_index.json") {
        // Do NOT create NLTextEmbedder here — it calls NLEmbedding.sentenceEmbedding(for:)
        // which loads a large ML model from disk and blocks @MainActor for several seconds.
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent(filename)
        load()

        // Warm the embedder on a background thread; flush any queued items when ready.
        Task.detached(priority: .utility) { [weak self] in
            let e = NLTextEmbedder()
            await MainActor.run { [weak self] in
                self?.embedder = e
                self?.flushPending()
            }
        }
    }

    // Process items that arrived before the embedder was ready.
    // IMPORTANT: embedder.embed() is CPU-intensive ML inference. Running it
    // synchronously on @MainActor for a batch of hundreds of items (common on
    // first launch or after clearing the index) freezes the UI for minutes.
    // Snapshot + clear pendingItems immediately, then embed off-MainActor.
    private func flushPending() {
        guard let embedder, !pendingItems.isEmpty else { return }
        let toProcess = pendingItems.filter { item in
            !entries.contains(where: { $0.id == item.id })
        }
        pendingItems.removeAll()
        guard !toProcess.isEmpty else { return }

        // Capture embedder reference so the detached task can use it.
        Task.detached(priority: .utility) { [weak self, embedder] in
            var newEntries: [SemanticEntry] = []
            for item in toProcess {
                let vec = embedder.embed(item.text)
                newEntries.append(SemanticEntry(id: item.id, text: item.text,
                                                embedding: vec, addedAt: Date()))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for entry in newEntries {
                    guard !self.entries.contains(where: { $0.id == entry.id }) else { continue }
                    self.entries.append(entry)
                }
                if self.entries.count > self.maxEntries {
                    self.entries = Array(self.entries.suffix(self.maxEntries))
                }
                self.save()
                self.log.debug("Flushed \(newEntries.count) pending semantic items")
            }
        }
    }

    // MARK: - Indexing

    /// Index a single item. No-op if the ID is already indexed.
    /// If the embedder is still warming up, queues the item for later processing.
    func index(id: String, text: String) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        guard let embedder else {
            if !pendingItems.contains(where: { $0.id == id }) {
                pendingItems.append((id: id, text: text))
            }
            return
        }
        let vec = embedder.embed(text)
        let entry = SemanticEntry(id: id, text: text, embedding: vec, addedAt: Date())
        entries.append(entry)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        save()
    }

    /// Index a batch of items. Skips items whose IDs are already present.
    /// If the embedder is still warming up, queues all items for later processing.
    func indexBatch(_ items: [(id: String, text: String)]) {
        guard let embedder else {
            for item in items {
                if !entries.contains(where: { $0.id == item.id }),
                   !pendingItems.contains(where: { $0.id == item.id }) {
                    pendingItems.append(item)
                }
            }
            return
        }
        var changed = false
        for item in items {
            guard !entries.contains(where: { $0.id == item.id }) else { continue }
            let vec = embedder.embed(item.text)
            entries.append(SemanticEntry(id: item.id, text: item.text, embedding: vec, addedAt: Date()))
            changed = true
        }
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        if changed { save() }
    }

    // MARK: - Search

    /// Returns the top-N most semantically similar entries for the query.
    /// Scores are decay-weighted by entry age (half-life 60 days) before ranking,
    /// so recently-added entries surface preferentially when similarity is equal.
    /// Returns empty if the embedder is still warming up.
    func search(query: String, limit: Int = 5, threshold: Float? = nil) -> [SemanticEntry] {
        guard !entries.isEmpty, let embedder else { return [] }
        let effectiveThreshold = threshold ?? defaultSimilarityThreshold
        let queryVec = embedder.embed(query)
        return entries
            .map { ($0, decayScore(cosine(queryVec, $0.embedding), createdAt: $0.addedAt)) }
            .filter { $0.1 >= effectiveThreshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Applies a recency decay multiplier to a raw similarity score.
    /// Half-life of 60 days: score decays to 50% at 60 days, ~25% at 120 days.
    /// Entries from today are returned at full score.
    private func decayScore(_ baseScore: Float, createdAt: Date) -> Float {
        let ageInDays = Date().timeIntervalSince(createdAt) / 86400
        let decayFactor = pow(0.5, Float(ageInDays / 60.0))
        return baseScore * decayFactor
    }

    // MARK: - Persistence

    var entryCount: Int { entries.count }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SemanticEntry].self, from: data)
        else { return }
        entries = decoded
        log.debug("Loaded \(decoded.count) semantic entries from disk")
    }

    // Save is called after mutating entries. Encode on a utility queue so
    // the atomic file write never blocks @MainActor.
    private func save() {
        let snapshot = entries
        let dest     = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: dest, options: .atomic)
        }
    }
}
