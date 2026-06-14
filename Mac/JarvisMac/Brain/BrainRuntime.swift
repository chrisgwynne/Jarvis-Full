import Foundation
import os

// MARK: - BrainRuntime

/// RuntimeSubsystem wrapper for the Brain layer.
///
/// Startup order 25 — after MemoryRuntime (20), before AudioRuntime (30).
/// Opens its own SQLite connection (WAL mode supports multiple readers/writers
/// on the same file). Configures BrainMemoryStore, BrainTaskQueue, and
/// EpisodeStore, then kicks off startup maintenance (expiry sweep).
///
/// Hard dependency: memory (system must be up before brain persists anything).
/// Soft dependency: llm (brain degrades gracefully without LLM for now).
@MainActor
final class BrainRuntime: RuntimeSubsystem {

    let id          = "brain"
    let displayName = "Brain Runtime"
    let startupOrder = 25

    private(set) var state: RuntimeState = .stopped

    private var db: JarvisDatabase?
    private let log = Logger(subsystem: "com.jarvis", category: "runtime.brain")

    // MARK: - Bridges (owned here so they are never deallocated)

    private var episodeBridge:    EpisodeBrainBridge?
    private var githubBridge:     GitHubBrainBridge?
    private var haBridge:         HABrainBridge?
    private var dreamCycle:       BrainDreamCycle?
    private var entityLifecycle:  EntityLifecycleCoordinator?
    private var heartbeat:        HeartbeatCoordinator?

    // MARK: - Start / Stop

    func start() async throws {
        state = .starting
        do {
            let database = try JarvisDatabase(url: JarvisDatabase.standardURL)
            self.db = database

            let semanticIndex = SemanticMemoryIndex(filename: "brain_semantic_index.json")

            BrainMemoryStore.shared.configure(db: database, semanticIndex: semanticIndex)
            BrainTaskQueue.shared.configure(db: database)
            EpisodeStore.shared.configure(db: database)

            // Maintenance pass — run off MainActor so it doesn't block startup
            Task.detached(priority: .utility) {
                await BrainMemoryStore.shared.sweepExpired()
            }

            // Load episodic memory from previous session
            EpisodicMemoryStore.shared.loadFromDisk()
            // Start background consolidation cycle
            MemoryConsolidationWorker.shared.start()

            // Start SystemBus bridges
            let episode = EpisodeBrainBridge(); episode.start(); self.episodeBridge = episode
            let github  = GitHubBrainBridge();  github.start();  self.githubBridge  = github
            let ha      = HABrainBridge();       ha.start();      self.haBridge      = ha

            // Start dream cycle (consolidation every 2 hours)
            let dream = BrainDreamCycle(); dream.start(); self.dreamCycle = dream

            // Start entity memory lifecycle (SystemBus subscriber + prune loop)
            EntityMemoryGraph.shared.loadFromDisk()
            let entityLC = EntityLifecycleCoordinator.shared; entityLC.start()
            self.entityLifecycle = entityLC

            // Start heartbeat coordinator (live "current state" pulse).
            // HeartbeatStore loads from disk in its initializer.
            HeartbeatCoordinator.shared.start()
            self.heartbeat = HeartbeatCoordinator.shared

            state = .running
            log.info("BrainRuntime started")
        } catch {
            state = .failed
            log.error("BrainRuntime failed to start: \(error.localizedDescription)")
            throw error
        }
    }

    func stop() async {
        episodeBridge?.stop();   episodeBridge   = nil
        githubBridge?.stop();    githubBridge    = nil
        haBridge?.stop();        haBridge        = nil
        dreamCycle?.stop();      dreamCycle      = nil
        entityLifecycle?.stop(); entityLifecycle = nil
        heartbeat?.stop();       heartbeat       = nil
        db = nil
        state = .stopped
        log.info("BrainRuntime stopped")
    }

    func healthCheck() async -> HealthStatus {
        guard db != nil else {
            return .degraded("No database connection")
        }
        return .healthy
    }
}
