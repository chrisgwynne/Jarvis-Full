import Foundation
import os

// MARK: - ReadinessState

enum ReadinessState: Equatable {
    case booting
    case ready
    case degraded(Set<String>)  // degraded subsystem IDs
    case failed

    var isOperational: Bool {
        switch self {
        case .ready, .degraded: return true
        case .booting, .failed: return false
        }
    }

    var displayName: String {
        switch self {
        case .booting:          return "Booting"
        case .ready:            return "Ready"
        case .degraded(let ids): return "Degraded (\(ids.sorted().joined(separator: ",")))"
        case .failed:           return "Failed"
        }
    }
}

// MARK: - RuntimeCoordinator

/// Central runtime coordinator. Owns startup sequencing, subsystem registry,
/// health monitoring, and isolated recovery. The single source of truth for
/// whether Jarvis is operational.
///
/// JarvisController calls `markReady()` after bootstrap. Individual subsystems
/// register themselves via `register()`. The coordinator polls health every 30 s
/// and attempts isolated recovery for any subsystem that degrades or fails.
@MainActor
final class RuntimeCoordinator {

    static let shared = RuntimeCoordinator()

    // MARK: - State

    private(set) var readiness: ReadinessState = .booting
    private(set) var subsystems: [String: any RuntimeSubsystem] = [:]
    private(set) var lastHealthSnapshot: [String: HealthStatus] = [:]
    private(set) var restartCounts: [String: Int] = [:]

    var healthCheckIntervalSeconds: TimeInterval = 30.0
    let maxRestartAttempts = 3

    private var healthMonitorTask: Task<Void, Never>?

    // MARK: - Registration

    func register(_ subsystem: any RuntimeSubsystem) {
        subsystems[subsystem.id] = subsystem
        lastHealthSnapshot[subsystem.id] = .healthy
        restartCounts[subsystem.id] = 0
        Log.runtime.info("[RuntimeCoordinator] registered subsystem '\(subsystem.id)'")
    }

    // MARK: - Readiness

    /// Call after JarvisController finishes bootstrap — signals the system is live.
    func markReady() {
        readiness = .ready
        SystemBus.shared.publish(RuntimeReadyEvent())
        Log.runtime.info("[RuntimeCoordinator] system READY")
        startHealthMonitor()
    }

    /// Call when bootstrap completes but some subsystems are degraded.
    func markDegradedReady(_ degradedIDs: Set<String>) {
        readiness = .degraded(degradedIDs)
        SystemBus.shared.publish(RuntimeReadyEvent())
        Log.runtime.warning("[RuntimeCoordinator] system ready (degraded: \(degradedIDs.sorted().joined(separator: ",")))")
        startHealthMonitor()
    }

    // MARK: - Health monitor

    func startHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.healthCheckIntervalSeconds ?? 30) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.runHealthChecks()
            }
        }
    }

    func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    func runHealthChecks() async {
        var degradedIDs = Set<String>()
        for subsystem in sortedSubsystems {
            let status = await subsystem.healthCheck()
            let prev = lastHealthSnapshot[subsystem.id]
            lastHealthSnapshot[subsystem.id] = status

            switch status {
            case .healthy:
                if prev?.isFailed == true || prev?.reason != nil {
                    Log.runtime.info("[RuntimeCoordinator] '\(subsystem.id)' recovered to healthy")
                }
            case .degraded(let reason):
                degradedIDs.insert(subsystem.id)
                Log.runtime.warning("[RuntimeCoordinator] '\(subsystem.id)' degraded: \(reason)")
            case .failed(let reason):
                degradedIDs.insert(subsystem.id)
                Log.runtime.error("[RuntimeCoordinator] '\(subsystem.id)' FAILED: \(reason)")
                if subsystem.canRecoverIndependently {
                    await attemptRecovery(id: subsystem.id)
                } else {
                    SystemBus.shared.publish(SubsystemFailedEvent(subsystemID: subsystem.id, reason: reason))
                }
            }
        }

        // Update overall readiness
        if degradedIDs.isEmpty {
            if case .degraded = readiness { readiness = .ready }
        } else {
            readiness = .degraded(degradedIDs)
        }
    }

    // MARK: - Recovery

    func attemptRecovery(id: String) async {
        guard let subsystem = subsystems[id] else { return }
        let attempts = (restartCounts[id] ?? 0) + 1
        restartCounts[id] = attempts

        if attempts > maxRestartAttempts {
            Log.runtime.error("[RuntimeCoordinator] '\(id)' exceeded max restarts (\(self.maxRestartAttempts)), giving up")
            SystemBus.shared.publish(SubsystemFailedEvent(subsystemID: id, reason: "Exceeded max restart attempts"))
            return
        }

        Log.runtime.info("[RuntimeCoordinator] attempting recovery of '\(id)' (attempt \(attempts))")
        do {
            try await subsystem.recover()
            restartCounts[id] = 0
            SystemBus.shared.publish(SubsystemRecoveredEvent(subsystemID: id, attemptCount: attempts))
            Log.runtime.info("[RuntimeCoordinator] '\(id)' recovered successfully")
        } catch {
            Log.runtime.error("[RuntimeCoordinator] '\(id)' recovery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    var sortedSubsystems: [any RuntimeSubsystem] {
        subsystems.values.sorted { $0.startupOrder < $1.startupOrder }
    }

    var isReady: Bool { readiness.isOperational }
}
