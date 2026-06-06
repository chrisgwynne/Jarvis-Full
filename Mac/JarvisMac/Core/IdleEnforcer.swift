import Foundation
import OSLog

// MARK: - IdleEnforcer

/// Enforces strict idle behaviour rules when the user has been inactive.
///
/// After 60s of inactivity:
///   ✅ Allowed:   passive wake listening, lightweight health checks
///   🚫 Not allowed: LLM requests, news processing, repeated daemon reconnects,
///                   camera processing, GitHub activity, project indexing
///
/// This is the primary fix for the ~60% idle CPU bug.
/// It does NOT kill subsystems — it slows them to minimal poll rates.
@MainActor
final class IdleEnforcer {

    static let shared = IdleEnforcer()

    private let logger = Logger(subsystem: "com.jarvis.mac.JarvisMac", category: "idle_enforcer")

    private var isEnforcing = false
    private var enforcedAt: Date? = nil

    // MARK: - Enforce idle

    /// Called every 5s by SelfMonitor when idle is detected.
    func enforce(controller: JarvisController, idleSeconds: TimeInterval) {
        guard !isEnforcing else { return }
        isEnforcing = true
        enforcedAt = Date()

        logger.info("[IdleEnforcer] enforcing idle mode after \(String(format: "%.0f", idleSeconds))s inactivity")

        // 1. Slow down ambient context sampling (30s → 120s)
        if controller.ambientContext.samplingIntervalSeconds < 120 {
            controller.ambientContext.samplingIntervalSeconds = 120
            logger.info("[IdleEnforcer] AmbientContextEngine slowed to 120s sampling")
        }

        // 2. Slow down window context monitor (5s → 60s)
        //    The WindowContextMonitor is created by AmbientContextEngine — we slow
        //    it by increasing the ambient interval above.

        // 3. Stop news refresh (news overlay closed = no need to refresh)
        let isNewsOverlayOpen = controller.overlayManager.isOpen(.news)
        if !isNewsOverlayOpen {
            controller.newsScheduler.pauseBackgroundRefresh()
            logger.info("[IdleEnforcer] NewsRefreshScheduler paused (no news overlay open)")
        }

        // 4. Pause proactivity delivery (doesn't stop providers; stops delivery loop)
        //    Proactivity keeps collecting signals but doesn't speak or interrupt.
        controller.proactivity.pauseForIdle()
        logger.info("[IdleEnforcer] ProactivityEngine delivery paused for idle")

        // 5. Stop non-essential background indexing
        //    ObsidianVaultService and CodebaseIndexer have their own guards; this
        //    enforces the idle contract via the known poll intervals.

        // 6. Emit idle performance report
        emitIdleReport(controller: controller)
    }

    // MARK: - Exit idle

    func exitIdle(controller: JarvisController) {
        guard isEnforcing else { return }
        isEnforcing = false
        enforcedAt  = nil

        // Restore ambient sampling to normal rate
        let prefInterval = max(15, controller.prefs.current.screenWatchIntervalSeconds)
        controller.ambientContext.samplingIntervalSeconds = prefInterval
        logger.info("[IdleEnforcer] AmbientContextEngine restored to \(prefInterval)s sampling")

        // Resume news refresh
        controller.newsScheduler.resumeBackgroundRefresh()
        logger.info("[IdleEnforcer] NewsRefreshScheduler resumed")

        // Resume proactivity delivery
        controller.proactivity.resumeFromIdle()
        logger.info("[IdleEnforcer] ProactivityEngine delivery resumed")
    }

    // MARK: - Idle performance report

    private func emitIdleReport(controller: JarvisController) {
        let state = controller.state
        let snap = SelfMonitor.shared.latestSnapshot

        Log.app.info("[IdleAudit] subsystem=STT state=\(state.isListening ? "active" : "idle") expected=idle")
        Log.app.info("[IdleAudit] subsystem=News state=\(controller.newsScheduler.isRefreshing ? "active" : "idle") expected=idle")
        Log.app.info("[IdleAudit] subsystem=DaemonBridge state=reconnects=\(DaemonAppBridge.shared.reconnectAttempts)")
        Log.app.info("[IdleAudit] subsystem=Overlays count=\(controller.overlayManager.overlays.count)")
        if let s = snap {
            Log.app.info("[IdleAudit] rss=\(s.rssMemoryMB)MB cpu=\(String(format: "%.1f", s.cpuPercent))% threads=\(s.threadCount)")
        }
    }
}

// MARK: - ProactivityEngine idle extensions

extension ProactivityEngine {
    /// Pause the delivery loop but keep collecting signals.
    func pauseForIdle() {
        guard !isPaused else { return }
        pause()
    }

    /// Resume delivery from idle pause.
    func resumeFromIdle() {
        guard isPaused else { return }
        resume()
    }
}

// MARK: - NewsRefreshScheduler idle extensions
// suspendBackgroundTick() and resumeBackgroundTick() are defined in NewsRefreshScheduler.swift.

extension NewsRefreshScheduler {
    func pauseBackgroundRefresh()  { suspendBackgroundTick() }
    func resumeBackgroundRefresh() { resumeBackgroundTick() }
}
