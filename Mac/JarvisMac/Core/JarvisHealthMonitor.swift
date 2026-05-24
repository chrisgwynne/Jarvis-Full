import Foundation
import Darwin.Mach

/// Watches Jarvis's own resident-memory footprint on a background `Task`
/// and fires `onEmergencyStop` on the `MainActor` if the threshold is exceeded.
///
/// Running on a detached Task means a blocked `@MainActor` queue never
/// starves the watchdog — it will still fire even when SwiftUI is busy.
@MainActor
final class JarvisHealthMonitor {

    // MARK: - Configuration

    /// Resident memory (MB) above which `onEmergencyStop` fires. Default 800 MB.
    var memoryThresholdMB: Int = 800

    /// How often (seconds) to poll. Default 15 s.
    var pollIntervalSeconds: Double = 15.0

    // MARK: - Observed state

    private(set) var lastResidentMB: Int = 0
    private(set) var emergencyStopFired: Bool = false

    // MARK: - Callback

    /// Called on `@MainActor` the first time the threshold is exceeded.
    var onEmergencyStop: ((String) -> Void)?

    // MARK: - Private

    private var monitorTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard monitorTask == nil else { return }
        CrashBreadcrumbLog.shared.subsystemStart("health_monitor")
        monitorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                // Snapshot MainActor config off the hot path
                let (threshold, interval) = await MainActor.run {
                    (self.memoryThresholdMB, self.pollIntervalSeconds)
                }

                // Memory check is a static helper — safe off MainActor
                let mem = CrashBreadcrumbLog.residentMemoryMB()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastResidentMB = mem
                    guard mem > threshold, !self.emergencyStopFired else { return }
                    let reason = "resident_memory=\(mem)MB > threshold=\(threshold)MB"
                    CrashBreadcrumbLog.shared.emergencyStop(reason: reason)
                    self.emergencyStopFired = true
                    self.onEmergencyStop?(reason)
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        CrashBreadcrumbLog.shared.subsystemStop("health_monitor")
    }
}
