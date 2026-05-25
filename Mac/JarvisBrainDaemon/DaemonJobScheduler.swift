import Foundation
import OSLog

private let schedulerLogger = Logger(subsystem: "com.jarvis.brain", category: "scheduler")

// MARK: - DaemonJob protocol

/// A recurring job executed on the daemon's background queue.
protocol DaemonJob: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var intervalSeconds: TimeInterval { get }
    var cooldownSeconds: TimeInterval { get }
    var respectsQuietHours: Bool { get }
    var maxRetries: Int { get }

    func execute() async throws
}

// MARK: - Default implementations

extension DaemonJob {
    var cooldownSeconds: TimeInterval { intervalSeconds }
    var respectsQuietHours: Bool { true }
    var maxRetries: Int { 2 }
}

// MARK: - Per-job state

private final class JobState {
    let job: DaemonJob
    var lastRanAt: Date?
    var consecutiveFailures: Int = 0
    var runCount: Int = 0
    var lastError: String?
    var currentWorkItem: DispatchWorkItem?

    init(job: DaemonJob) {
        self.job = job
    }
}

// MARK: - DaemonJobScheduler

final class DaemonJobScheduler {
    static let shared = DaemonJobScheduler()
    private init() {}

    private var jobStates: [String: JobState] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.jarvis.brain.scheduler", qos: .utility)
    private var isPaused = false

    // MARK: - Registration

    /// Register a job and start scheduling it immediately.
    func register(_ job: DaemonJob) {
        lock.withLock {
            guard jobStates[job.id] == nil else {
                schedulerLogger.warning("scheduler: job already registered id=\(job.id)")
                return
            }
            let state = JobState(job: job)
            jobStates[job.id] = state
            schedulerLogger.info("scheduler: registered job id=\(job.id) name=\(job.displayName) interval=\(job.intervalSeconds)s")
        }
        scheduleNext(jobId: job.id, delay: 0)
    }

    /// Unregister a job and cancel any pending work.
    func unregister(id: String) {
        lock.withLock {
            if let state = jobStates[id] {
                state.currentWorkItem?.cancel()
                jobStates.removeValue(forKey: id)
                schedulerLogger.info("scheduler: unregistered job id=\(id)")
            }
        }
    }

    // MARK: - Pause / Resume

    func pauseAll() {
        lock.withLock {
            isPaused = true
            for state in jobStates.values {
                state.currentWorkItem?.cancel()
                state.currentWorkItem = nil
            }
            schedulerLogger.info("scheduler: paused all jobs")
        }
    }

    func resumeAll() {
        let jobIds: [String] = lock.withLock {
            isPaused = false
            return Array(jobStates.keys)
        }
        for id in jobIds {
            scheduleNext(jobId: id, delay: 0)
        }
        schedulerLogger.info("scheduler: resumed all jobs count=\(jobIds.count)")
    }

    // MARK: - Diagnostics

    var jobSummary: String {
        lock.withLock {
            let total = jobStates.count
            let running = jobStates.values.filter { $0.currentWorkItem != nil && !isPaused }.count
            let paused = isPaused ? total : 0
            let failures = jobStates.values.reduce(0) { $0 + $1.consecutiveFailures }
            return "jobs=\(total) running=\(running) paused=\(paused) failures=\(failures)"
        }
    }

    var allJobStatuses: [(id: String, name: String, lastRan: Date?, lastError: String?, runCount: Int)] {
        lock.withLock {
            jobStates.values.map { state in
                (
                    id: state.job.id,
                    name: state.job.displayName,
                    lastRan: state.lastRanAt,
                    lastError: state.lastError,
                    runCount: state.runCount
                )
            }
        }
    }

    // MARK: - Private scheduling

    private func scheduleNext(jobId: String, delay: TimeInterval) {
        let shouldSkip: Bool = lock.withLock {
            guard !isPaused, let state = jobStates[jobId] else { return true }

            // Cancel any previously scheduled work item
            state.currentWorkItem?.cancel()
            state.currentWorkItem = nil

            // Check quiet hours at schedule time
            if state.job.respectsQuietHours && isQuietHours() {
                schedulerLogger.debug("scheduler: quiet hours — deferring job id=\(jobId)")
                // Re-schedule at a sensible wake-up time (check again in 30 min)
                let workItem = DispatchWorkItem { [weak self] in
                    self?.scheduleNext(jobId: jobId, delay: 0)
                }
                state.currentWorkItem = workItem
                self.queue.asyncAfter(deadline: .now() + 1800, execute: workItem)
                return true
            }
            return false
        }

        if shouldSkip { return }

        let workItem = makeWorkItem(jobId: jobId)
        lock.withLock {
            guard let state = jobStates[jobId] else { return }
            state.currentWorkItem = workItem
        }
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeWorkItem(jobId: String) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runJob(jobId: jobId)
        }
    }

    private func runJob(jobId: String) {
        // Fetch job reference safely
        let jobRef: DaemonJob? = lock.withLock { jobStates[jobId]?.job }
        guard let job = jobRef else { return }

        schedulerLogger.debug("scheduler: executing job id=\(jobId)")

        Task {
            do {
                try await job.execute()

                // On success — reset consecutive failures
                let nextInterval: TimeInterval = self.lock.withLock {
                    guard let state = self.jobStates[jobId] else { return job.intervalSeconds }
                    state.consecutiveFailures = 0
                    state.lastError = nil
                    state.lastRanAt = Date()
                    state.runCount += 1
                    return job.intervalSeconds
                }
                schedulerLogger.debug("scheduler: job succeeded id=\(jobId) nextIn=\(nextInterval)s")
                self.scheduleNext(jobId: jobId, delay: max(nextInterval, job.cooldownSeconds))

            } catch {
                // On failure — log, increment consecutiveFailures, apply exponential backoff
                let nextInterval: TimeInterval = self.lock.withLock {
                    guard let state = self.jobStates[jobId] else { return job.intervalSeconds }
                    state.consecutiveFailures += 1
                    state.lastError = error.localizedDescription
                    state.lastRanAt = Date()
                    state.runCount += 1

                    // Exponential backoff after 3 consecutive failures, capped at 4× normal
                    if state.consecutiveFailures >= 3 {
                        let backoffMultiplier = min(Double(state.consecutiveFailures - 2), 4.0)
                        return job.intervalSeconds * backoffMultiplier
                    }
                    return job.intervalSeconds
                }
                schedulerLogger.error("scheduler: job failed id=\(jobId) error=\(error.localizedDescription) nextIn=\(nextInterval)s")
                self.scheduleNext(jobId: jobId, delay: nextInterval)
            }
        }
    }

    // MARK: - Quiet hours helper (22:00–07:00 local time)

    private func isQuietHours() -> Bool {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date())
        return hour >= 22 || hour < 7
    }
}
