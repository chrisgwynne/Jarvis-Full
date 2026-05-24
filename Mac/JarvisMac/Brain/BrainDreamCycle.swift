import Foundation
import os

// MARK: - BrainDreamCycle

/// Periodic background consolidation: promotes high-confidence memory candidates
/// from ConversationMemoryStore into BrainMemoryStore, sweeps expired entries,
/// and closes abandoned episodes.
///
/// Runs every 2 hours on a detached utility task. Never touches the main actor
/// during the heavy work; only calls BrainMemoryStore / EpisodeStore on MainActor
/// at the end via Task { @MainActor in ... }.
///
/// Extracted as a standalone class so BrainRuntime can start/stop it cleanly.
@MainActor
final class BrainDreamCycle {

    // MARK: - Config

    /// How often the dream cycle fires (in seconds).
    static let intervalSeconds: Double = 7200  // 2 hours

    /// Minimum confidence for a ConversationMemoryStore candidate to be promoted.
    private let promotionThreshold: Double = 0.65

    /// Episodes idle longer than this are auto-closed.
    private let abandonedEpisodeHours: Double = 4

    // MARK: - State

    private var cycleTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.jarvis", category: "brain.dream")
    private(set) var lastRunAt: Date?
    private(set) var cycleCount: Int = 0

    // MARK: - Lifecycle

    func start() {
        guard cycleTask == nil else { return }
        cycleTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Initial delay: let the app fully boot before the first cycle.
            try? await Task.sleep(for: .seconds(300))
            while !Task.isCancelled {
                await self.runCycle()
                try? await Task.sleep(for: .seconds(BrainDreamCycle.intervalSeconds))
            }
        }
        log.info("brain.dream: cycle started (interval=\(BrainDreamCycle.intervalSeconds)s)")
    }

    func stop() {
        cycleTask?.cancel()
        cycleTask = nil
        log.info("brain.dream: cycle stopped")
    }

    // MARK: - Cycle

    @MainActor
    func runCycle() async {
        cycleCount += 1
        lastRunAt = Date()
        let cycleNum = cycleCount
        log.info("brain.dream: cycle #\(cycleNum) starting")

        let promoted = await promoteMemories()
        await BrainMemoryStore.shared.sweepExpired()
        closeAbandonedEpisodes()

        log.info("brain.dream: cycle #\(cycleNum) done — promoted=\(promoted)")
    }

    // MARK: - Memory promotion

    @MainActor
    private func promoteMemories() async -> Int {
        let candidates = ConversationMemoryStore.shared.memoryItems
            .filter { $0.confidence >= promotionThreshold && $0.type != .discard }

        var count = 0
        for candidate in candidates {
            var brain = candidate
            brain.source = .dreamCycle
            brain.importance = max(brain.importance, importanceFor(candidate.type))

            let committed = await BrainMemoryStore.shared.commit(brain)
            if committed {
                EpisodeStore.shared.linkMemory(brain.id.uuidString)
                count += 1
            }
        }
        return count
    }

    // MARK: - Episode cleanup

    @MainActor
    private func closeAbandonedEpisodes() {
        guard let ep = EpisodeStore.shared.activeEpisode else { return }
        let idleHours = -ep.startedAt.timeIntervalSinceNow / 3600
        guard idleHours > abandonedEpisodeHours else { return }
        EpisodeStore.shared.endActiveEpisode(summary: "Auto-closed after \(Int(idleHours))h idle.")
        log.info("brain.dream: closed abandoned episode '\(ep.title)' idle=\(Int(idleHours))h")
    }

    // MARK: - Importance mapping (mirrors JarvisController.brainImportance)

    private func importanceFor(_ type: MemoryCandidateType) -> Double {
        switch type {
        case .roadmapChange:                return 0.85
        case .projectDecision:              return 0.80
        case .projectProgress, .personalFact: return 0.75
        case .userPreference:               return 0.70
        case .bugReport:                    return 0.65
        case .idea:                         return 0.60
        default:                            return 0.30
        }
    }
}
