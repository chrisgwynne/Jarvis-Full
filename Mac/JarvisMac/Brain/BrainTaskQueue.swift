import Foundation
import os

// MARK: - BrainTaskQueue

/// Durable, restart-safe task queue for long-running background work.
///
/// Tasks survive app restarts. On launch, BrainRuntime restores all
/// `queued` and `paused` tasks from SQLite. `running` tasks that are
/// found on launch are reset to `queued` (they did not complete cleanly).
///
/// This is an orchestration queue — it tracks work items and their status.
/// Actual execution is performed by workers that call `dequeueNext()` and
/// report progress via `update(id:progress:)` and `complete(id:error:)`.
///
/// Workers are responsible for respecting cancellation by checking
/// `task.status == .cancelled` periodically during long-running operations.
@MainActor
final class BrainTaskQueue {

    static let shared = BrainTaskQueue()

    // MARK: - Dependencies

    private var db: JarvisDatabase?
    private let log = Logger(subsystem: "com.jarvis", category: "brain.tasks")

    // MARK: - In-memory cache

    private(set) var tasks: [BrainTask] = []

    // MARK: - Configuration

    func configure(db: JarvisDatabase) {
        self.db = db
        restoreFromDisk()
    }

    // MARK: - Enqueueing

    /// Add a new task to the queue. No-ops if an identical active task already exists.
    @discardableResult
    func enqueue(_ task: BrainTask) -> BrainTask {
        // Prevent duplicate active tasks of the same type
        if tasks.contains(where: { $0.type == task.type && $0.status.isActive }) {
            log.debug("brain.tasks: skipping duplicate active task type \(task.type.rawValue)")
            return task
        }

        var t = task
        t.status    = .queued
        t.createdAt = Date()
        tasks.append(t)
        persist(t)
        SystemBus.shared.publish(BrainTaskQueuedEvent(
            taskId:    t.id,
            taskType:  t.type.rawValue,
            taskTitle: t.title
        ))
        log.info("brain.tasks: enqueued [\(t.type.rawValue)] \(t.title)")
        return t
    }

    // MARK: - Status transitions

    /// Mark a task as running and record its start time.
    func markRunning(id: String) {
        transition(id: id) { t in
            guard t.status == .queued || t.status == .paused else { return }
            t.status    = .running
            t.startedAt = Date()
        }
    }

    /// Update progress fraction (0.0–1.0) without changing status.
    func updateProgress(id: String, progress: Double) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].progress = max(0, min(1, progress))
            persist(tasks[idx])
        }
    }

    /// Mark a task completed successfully.
    func complete(id: String) {
        transition(id: id) { t in
            t.status      = .completed
            t.progress    = 1.0
            t.completedAt = Date()
            t.error       = nil
        }
    }

    /// Mark a task failed. Automatically re-queues if `retryCount < maxRetries`.
    func fail(id: String, error: String) {
        transition(id: id) { t in
            t.error      = error
            if t.retryCount < t.maxRetries {
                t.retryCount += 1
                t.status     = .queued
                t.startedAt  = nil
                let title = t.title; let attempt = t.retryCount; let max = t.maxRetries
                log.info("brain.tasks: re-queuing \(title) (attempt \(attempt)/\(max))")
            } else {
                t.status      = .failed
                t.completedAt = Date()
            }
        }
    }

    /// Pause a running task (can be resumed via `markRunning`).
    func pause(id: String) {
        transition(id: id) { t in
            guard t.status == .running else { return }
            t.status = .paused
        }
    }

    /// Cancel a task regardless of current state.
    func cancel(id: String) {
        transition(id: id) { t in
            guard !t.status.isTerminal else { return }
            t.status      = .cancelled
            t.completedAt = Date()
        }
    }

    // MARK: - Queries

    /// Next queued task ordered by priority then creation time.
    var nextQueued: BrainTask? {
        tasks.filter { $0.status == .queued }
            .sorted { $0.priority < $1.priority || ($0.priority == $1.priority && $0.createdAt < $1.createdAt) }
            .first
    }

    var activeTasks: [BrainTask] {
        tasks.filter { $0.status.isActive }
    }

    var userVisibleTasks: [BrainTask] {
        tasks.filter { $0.userVisible }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var pendingCount: Int {
        tasks.filter { $0.status == .queued }.count
    }

    /// All non-terminal tasks, sorted by priority then creation time.
    func allActive() -> [BrainTask] {
        tasks.filter { !$0.status.isTerminal }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.createdAt < rhs.createdAt
            }
    }

    // MARK: - Maintenance

    /// Remove terminal tasks older than `days` days.
    func purgeOld(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(Double(-days) * 86400)
        tasks.removeAll { t in
            t.status.isTerminal && (t.completedAt ?? t.createdAt) < cutoff
        }
        log.info("brain.tasks: purged old terminal tasks")
    }

    // MARK: - Private helpers

    private func transition(id: String, update: (inout BrainTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[idx]
        let oldStatus = t.status
        update(&t)
        tasks[idx] = t
        persist(t)
        if t.status != oldStatus {
            SystemBus.shared.publish(BrainTaskStatusChangedEvent(
                taskId:    t.id,
                newStatus: t.status.rawValue,
                taskTitle: t.title
            ))
        }
    }

    private func persist(_ task: BrainTask) {
        guard let db else { return }
        let tagsJSON = (try? String(data: JSONSerialization.data(withJSONObject: task.tags), encoding: .utf8)) ?? "[]"
        try? db.upsertBrainTask(
            id:          task.id,
            title:       task.title,
            type:        task.type.rawValue,
            status:      task.status.rawValue,
            priority:    task.priority,
            createdAt:   task.createdAt,
            startedAt:   task.startedAt,
            completedAt: task.completedAt,
            error:       task.error,
            retryCount:  task.retryCount,
            maxRetries:  task.maxRetries,
            payloadJSON: task.payloadJSON,
            progress:    task.progress,
            userVisible: task.userVisible,
            tagsJSON:    tagsJSON
        )
    }

    private func restoreFromDisk() {
        guard let db else { return }
        let rows = (try? db.allActiveBrainTasks()) ?? []
        tasks = rows.compactMap { row -> BrainTask? in
            guard let type   = BrainTaskType(rawValue: row.type),
                  var status = BrainTaskStatus(rawValue: row.status) else { return nil }
            // Tasks that were `running` on the previous launch did not complete
            // cleanly — reset them to `queued` so they are retried.
            if status == .running { status = .queued }
            var t = BrainTask(title: row.title, type: type)
            t.id          = row.id
            t.status      = status
            t.priority    = row.priority
            t.createdAt   = row.createdAt
            t.startedAt   = row.startedAt
            t.completedAt = row.completedAt
            t.error       = row.error
            t.retryCount  = row.retryCount
            t.maxRetries  = row.maxRetries
            t.payloadJSON = row.payloadJSON
            t.progress    = row.progress
            t.userVisible = row.userVisible
            return t
        }
        log.info("brain.tasks: restored \(self.tasks.count) active tasks from disk")
    }
}
