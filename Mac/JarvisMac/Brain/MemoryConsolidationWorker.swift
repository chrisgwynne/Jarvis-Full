import Foundation
import os

// MARK: - ConsolidationResult

struct ConsolidationResult {
    var mergedCount: Int = 0
    var resolvedCount: Int = 0
    var decayedCount: Int = 0
    var promotedCount: Int = 0

    var isEmpty: Bool {
        mergedCount == 0 && resolvedCount == 0 && decayedCount == 0 && promotedCount == 0
    }

    var summary: String {
        var parts: [String] = []
        if mergedCount > 0   { parts.append("merged \(mergedCount)") }
        if resolvedCount > 0 { parts.append("resolved \(resolvedCount)") }
        if decayedCount > 0  { parts.append("decayed \(decayedCount)") }
        if promotedCount > 0 { parts.append("promoted \(promotedCount)") }
        return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
    }
}

// MARK: - MemoryConsolidationWorker

/// Background worker that sweeps `EpisodicMemoryStore` to:
/// 1. **Merge** near-duplicate entries into a single record.
/// 2. **Resolve** entries superseded by later decisions.
/// 3. **Decay** low-importance old entries.
/// 4. **Promote** high-importance entries to `BrainMemoryStore`.
///
/// Runs on detached utility Tasks — never blocks conversation flow.
@MainActor
final class MemoryConsolidationWorker {

    static let shared = MemoryConsolidationWorker()

    private let log = Logger(subsystem: "com.jarvis", category: "brain.consolidation")
    private var workerTask: Task<Void, Never>?

    // MARK: - Configuration

    var consolidationIntervalHours: Double = 4
    var duplicateSimilarityThreshold: Double = 0.72
    var decayAgeThresholdDays: Double = 45
    var decayImportanceThreshold: Double = 0.35
    var promotionImportanceThreshold: Double = 0.75

    // MARK: - Lifecycle

    func start() {
        workerTask?.cancel()
        workerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(consolidationIntervalHours * 3600))
                if !Task.isCancelled { await runConsolidation() }
            }
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
    }

    func runNow() async {
        await runConsolidation()
    }

    // MARK: - Pipeline

    private func runConsolidation() async {
        let result = consolidate()
        if !result.isEmpty {
            log.info("Consolidation: \(result.summary)")
        }
    }

    @discardableResult
    func consolidate() -> ConsolidationResult {
        var result = ConsolidationResult()
        let store = EpisodicMemoryStore.shared

        result.mergedCount   += mergeDuplicates(in: store)
        result.resolvedCount += autoResolveSuperseded(in: store)
        result.decayedCount  += decayOld(in: store)
        result.promotedCount += promoteHighImportance(in: store)

        return result
    }

    // MARK: - Merge

    private func mergeDuplicates(in store: EpisodicMemoryStore) -> Int {
        var merged = 0
        var toResolve: Set<String> = []
        let entries = store.entries

        for i in 0..<entries.count {
            guard !toResolve.contains(entries[i].id) else { continue }
            for j in (i + 1)..<entries.count {
                guard !toResolve.contains(entries[j].id) else { continue }
                guard entries[i].type == entries[j].type else { continue }
                if jaccardSimilarity(entries[i].text, entries[j].text) >= duplicateSimilarityThreshold {
                    let keepI = entries[i].importance >= entries[j].importance
                    toResolve.insert(keepI ? entries[j].id : entries[i].id)
                    merged += 1
                }
            }
        }
        for id in toResolve { store.markResolved(id) }
        return merged
    }

    // MARK: - Auto-resolve

    private func autoResolveSuperseded(in store: EpisodicMemoryStore) -> Int {
        var resolved = 0
        let decisions = store.unresolved(type: .projectDecision)
        var seen: [String: String] = [:]  // "project:topic" → id of newest
        for d in decisions.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = "\(d.projectName ?? "")::\(d.topic ?? "")"
            if seen[key] != nil {
                store.markResolved(d.id)
                resolved += 1
            } else {
                seen[key] = d.id
            }
        }
        return resolved
    }

    // MARK: - Decay

    private func decayOld(in store: EpisodicMemoryStore) -> Int {
        var decayed = 0
        for entry in store.entries
            where !entry.isResolved
                && entry.ageDays > decayAgeThresholdDays
                && entry.importance < decayImportanceThreshold
        {
            store.markResolved(entry.id)
            decayed += 1
        }
        return decayed
    }

    // MARK: - Promote

    private func promoteHighImportance(in store: EpisodicMemoryStore) -> Int {
        var promoted = 0
        let candidates = store.entries.filter {
            !$0.isResolved
            && $0.importance >= promotionImportanceThreshold
            && $0.confidence >= 0.65
        }
        for candidate in candidates {
            let already = BrainMemoryStore.shared.memories.contains { $0.title == candidate.title }
            guard !already else { continue }

            let mc = MemoryCandidate(
                type: candidate.type,
                tier: .projectMemory,
                title: candidate.title,
                summary: candidate.text,
                rawText: candidate.text,
                confidence: candidate.confidence,
                tags: [candidate.type.rawValue],
                createdAt: candidate.createdAt
            )
            Task { await BrainMemoryStore.shared.commit(mc) }
            promoted += 1
        }
        return promoted
    }

    // MARK: - Helpers

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let wa = Set(a.lowercased().split(separator: " ").map(String.init))
        let wb = Set(b.lowercased().split(separator: " ").map(String.init))
        let intersection = wa.intersection(wb)
        let union = wa.union(wb)
        return union.isEmpty ? 0 : Double(intersection.count) / Double(union.count)
    }
}
