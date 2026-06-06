import Foundation
import Darwin.Mach
import OSLog

// MARK: - SelfMonitor

/// Stability watchdog — polls every 5 seconds, keeps 15 minutes of history,
/// fires structured alerts when thresholds are exceeded, and pre-fills the
/// GitHub Issue Overlay with a diagnostic bundle before handing off to the user.
///
/// Design rules:
///   - All heavy work happens off the MainActor (Task.detached at .utility)
///   - Threshold checks happen on the MainActor with current app state
///   - Never silently creates GitHub issues — opens the overlay only
///   - Single singleton, started in JarvisController.bootstrap()
@MainActor
final class SelfMonitor {

    static let shared = SelfMonitor()

    // MARK: - Configuration
    var thresholds = WatchdogThresholds()
    var pollIntervalSeconds: TimeInterval = 5.0

    /// How many snapshots to keep (15 min × 12/min = 180).
    var maxHistory = 180

    // MARK: - State visible to the RuntimeProfiler overlay
    private(set) var snapshots: [SelfMonitorSnapshot] = []
    private(set) var latestSnapshot: SelfMonitorSnapshot? = nil
    private(set) var subsystemProfiles: [SubsystemProfile] = []
    private(set) var watchdogFiredAt: Date? = nil
    private(set) var watchdogReason: String = ""
    private(set) var isInSafeDegradedMode: Bool = false
    private(set) var idleSince: Date? = nil

    /// Rolling counters for the current 1-minute window
    private var logEventCount: Int = 0
    private var networkRequestCount: Int = 0
    private var wakeWordTriggerCount: Int = 0

    // MARK: - Private
    private let logger = Logger(subsystem: "com.jarvis.mac.JarvisMac", category: "selfmonitor")
    private var pollTask: Task<Void, Never>?
    private var idleAuditTask: Task<Void, Never>?
    private var consecutiveHighCPUSamples: Int = 0
    private var consecutiveMemoryGrowthSamples: Int = 0
    private var lastMemoryMB: Int = 0
    private var cpuBaseline: Double? = nil      // set during first 30s of idle
    private var watchdogCooldownUntil: Date = .distantPast

    // Weak back-reference to the controller for emergency actions.
    weak var controller: JarvisController?

    // MARK: - Diagnostics directory

    private static var diagnosticsDir: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("JarvisMac")
            .appendingPathComponent("Diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        logger.info("[SelfMonitor] starting poll interval=\(self.pollIntervalSeconds)s")
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.poll()
                try? await Task.sleep(for: .seconds(await self.pollIntervalSeconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        idleAuditTask?.cancel()
        idleAuditTask = nil
        logger.info("[SelfMonitor] stopped")
    }

    // MARK: - Counter increments (called from hot paths — cheap)

    func recordLogLine() { logEventCount += 1 }
    func recordNetworkRequest() { networkRequestCount += 1 }
    func recordWakeWordTrigger() { wakeWordTriggerCount += 1 }

    // MARK: - Idle tracking

    func recordUserInteraction() {
        let wasIdle = idleSince != nil
        idleSince = nil
        consecutiveHighCPUSamples = 0
        if wasIdle {
            logger.info("[SelfMonitor] user interaction — exiting idle mode")
            if let ctrl = controller { IdleEnforcer.shared.exitIdle(controller: ctrl) }
        }
    }

    func noteConversationEnded() {
        // Start idle clock after conversation ends
        if idleSince == nil { idleSince = Date() }
    }

    private var isCurrentlyIdle: Bool {
        guard let since = idleSince else { return false }
        return Date().timeIntervalSince(since) > thresholds.idleAfterSeconds
    }

    // MARK: - Main poll

    private func poll() async {
        let snap = await buildSnapshot()

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.latestSnapshot = snap
            self.snapshots.append(snap)
            if self.snapshots.count > self.maxHistory {
                self.snapshots.removeFirst(self.snapshots.count - self.maxHistory)
            }
            // Reset 1-minute counters every 12 samples (12 × 5s = 60s)
            if self.snapshots.count % 12 == 0 {
                self.logEventCount = 0
                self.networkRequestCount = 0
                self.wakeWordTriggerCount = 0
            }
            self.updateSubsystemProfiles(snap: snap)
            self.checkThresholds(snap: snap)
        }

        // Idle audit when user is inactive
        if await isCurrentlyIdle {
            await runIdleAudit(snap: snap)
        }
    }

    // MARK: - Snapshot builder (off-actor)

    private func buildSnapshot() async -> SelfMonitorSnapshot {
        // System metrics — safe off-actor
        let rss  = CrashBreadcrumbLog.residentMemoryMB()
        let cpu  = Self.processCPUPercent()
        let threads = Self.threadCount()
        let fds     = Self.openFileDescriptorCount()

        // App state — needs MainActor
        return await MainActor.run { [weak self] in
            guard let self, let ctrl = self.controller else {
                return SelfMonitorSnapshot(
                    timestamp: Date(), rssMemoryMB: rss, cpuPercent: cpu,
                    threadCount: threads, fdCount: fds,
                    isListening: false, isSpeaking: false,
                    wakeWordActive: false, sttSessionActive: false, ttsActive: false,
                    activeOverlayCount: 0, cameraStreaming: false,
                    newsJobsActive: false, proactivityActive: false,
                    daemonReconnectAttempts: 0, ambientSamplingActive: false,
                    logsPerMinute: 0, networkRequestsPerMinute: 0,
                    wakeWordTriggersPerMinute: 0
                )
            }
            let st = ctrl.state
            return SelfMonitorSnapshot(
                timestamp: Date(),
                rssMemoryMB: rss,
                cpuPercent: cpu,
                threadCount: threads,
                fdCount: fds,
                isListening: st.isListening,
                isSpeaking: st.isSpeaking,
                wakeWordActive: true,   // wake word is always expected to be armed
                sttSessionActive: st.isListening,
                ttsActive: st.isSpeaking,
                activeOverlayCount: ctrl.overlayManager.overlays.count,
                cameraStreaming: ctrl.state.cameraStatus.isHealthy,
                newsJobsActive: ctrl.newsScheduler.isRefreshing,
                proactivityActive: !ctrl.proactivity.isPaused,
                daemonReconnectAttempts: DaemonAppBridge.shared.reconnectAttempts,
                ambientSamplingActive: ctrl.ambientContext.samplingEnabled,
                logsPerMinute: self.logEventCount,
                networkRequestsPerMinute: self.networkRequestCount,
                wakeWordTriggersPerMinute: self.wakeWordTriggerCount
            )
        }
    }

    // MARK: - Threshold checks

    private func checkThresholds(snap: SelfMonitorSnapshot) {
        // Cooldown: don't fire watchdog more than once per 5 minutes
        guard Date() > watchdogCooldownUntil else { return }

        // Memory: absolute threshold
        if snap.rssMemoryMB > thresholds.maxMemoryMB {
            fireWatchdog(
                reason: "Memory above threshold: \(snap.rssMemoryMB)MB > \(thresholds.maxMemoryMB)MB",
                subsystem: "memory",
                severity: .high,
                snap: snap
            )
            return
        }

        // Memory: continuous growth
        if snap.rssMemoryMB > lastMemoryMB {
            consecutiveMemoryGrowthSamples += 1
            if consecutiveMemoryGrowthSamples >= thresholds.memoryGrowthSamples {
                fireWatchdog(
                    reason: "Memory growing continuously for \(consecutiveMemoryGrowthSamples * 5 / 60) min (now \(snap.rssMemoryMB)MB)",
                    subsystem: "memory_growth",
                    severity: .high,
                    snap: snap
                )
                consecutiveMemoryGrowthSamples = 0
                return
            }
        } else {
            consecutiveMemoryGrowthSamples = 0
        }
        lastMemoryMB = snap.rssMemoryMB

        // CPU while idle
        if snap.isIdle && snap.cpuPercent > thresholds.idleCPUPercent {
            consecutiveHighCPUSamples += 1
            if consecutiveHighCPUSamples >= thresholds.cpuWatchSamples {
                let topSystem = topCPUSubsystem(snap: snap)
                fireWatchdog(
                    reason: "CPU \(String(format: "%.1f", snap.cpuPercent))% while idle for \(consecutiveHighCPUSamples * 5 / 60) min. Likely: \(topSystem)",
                    subsystem: topSystem,
                    severity: .medium,
                    snap: snap
                )
                consecutiveHighCPUSamples = 0
                return
            }
        } else {
            consecutiveHighCPUSamples = 0
        }

        // Log spam
        if snap.logsPerMinute > thresholds.logSpamPerMinute {
            fireWatchdog(
                reason: "Log spam: \(snap.logsPerMinute) lines/min (threshold: \(thresholds.logSpamPerMinute))",
                subsystem: "logging",
                severity: .medium,
                snap: snap
            )
            return
        }

        // Daemon reconnect loop
        let daemonPerMin = snap.daemonReconnectAttempts
        if daemonPerMin >= thresholds.daemonReconnectLoopPerMin {
            fireWatchdog(
                reason: "Daemon reconnect loop detected: \(daemonPerMin) attempts",
                subsystem: "daemon_bridge",
                severity: .medium,
                snap: snap
            )
            return
        }

        // Overlay count runaway
        if snap.activeOverlayCount > thresholds.maxOverlayCount {
            fireWatchdog(
                reason: "Overlay count runaway: \(snap.activeOverlayCount) overlays open",
                subsystem: "overlay_manager",
                severity: .medium,
                snap: snap
            )
            return
        }
    }

    // MARK: - Watchdog fire

    private func fireWatchdog(
        reason: String,
        subsystem: String,
        severity: GitHubIssueSeverity,
        snap: SelfMonitorSnapshot
    ) {
        watchdogFiredAt = Date()
        watchdogReason  = reason
        watchdogCooldownUntil = Date().addingTimeInterval(300) // 5-minute cooldown

        logger.warning("[SelfMonitor] WATCHDOG fired: \(reason)")

        // Write diagnostic bundle to disk
        Task.detached(priority: .utility) { [weak self] in
            await self?.writeDiagnosticBundle(reason: reason, subsystem: subsystem, snap: snap)
        }

        // Decide whether to enter safe degraded mode
        let requiresSafeMode = snap.rssMemoryMB > thresholds.maxMemoryMB
                             || snap.cpuPercent > 90
        if requiresSafeMode { enterSafeDegradedMode(reason: reason) }

        // Open GitHub Issue Overlay (never silently creates)
        openStabilityIssueOverlay(reason: reason, subsystem: subsystem, severity: severity, snap: snap)
    }

    // MARK: - Safe degraded mode

    func enterSafeDegradedMode(reason: String) {
        guard !isInSafeDegradedMode else { return }
        isInSafeDegradedMode = true
        logger.warning("[SelfMonitor] entering SAFE DEGRADED MODE: \(reason)")

        guard let ctrl = controller else { return }
        // Stop high-cost subsystems to prevent crash
        ctrl.proactivity.pause()
        ctrl.newsScheduler.stop()
        ctrl.ambientContext.setEnabled(false)
        // Close all non-essential overlays
        ctrl.overlayManager.closeAll(except: [.githubIssue])
        // Show banner in UI
        ctrl.state.safeModeActive = true
        ctrl.state.safeModeReason = "Jarvis entered Safe Mode to prevent a crash: \(reason)"
        ctrl.showToast("⚠️ Jarvis entered Safe Mode", icon: "exclamationmark.shield.fill")
        CrashBreadcrumbLog.shared.write(subsystem: "selfmonitor", action: "safe_mode", detail: reason)
    }

    func exitSafeDegradedMode() {
        guard isInSafeDegradedMode else { return }
        isInSafeDegradedMode = false
        controller?.state.safeModeActive = false
        controller?.state.safeModeReason = ""
        logger.info("[SelfMonitor] exiting safe degraded mode")
    }

    // MARK: - GitHub Issue Overlay pre-fill

    private func openStabilityIssueOverlay(
        reason: String,
        subsystem: String,
        severity: GitHubIssueSeverity,
        snap: SelfMonitorSnapshot
    ) {
        guard let ctrl = controller else { return }
        let body = buildStabilityDiagnosticBody(reason: reason, snap: snap)
        let opened = GitHubIssueDraftStore.shared.openForError(
            title: "[Stability] Jarvis approaching crash: \(reason.prefix(80))",
            description: body,
            area: .macApp,
            severity: severity,
            logs: recentBreadcrumbs(),
            signature: "stability_\(subsystem)",
            defaultRepo: ctrl.defaultGitHubRepo
        )
        if opened { ctrl.overlayManager.open(.githubIssue) }
    }

    /// Open the overlay for a manual stability report ("run stability report").
    func openManualStabilityReport(controller: JarvisController) {
        let snap = latestSnapshot ?? buildEmptySnapshot()
        let suspect = topSuspectJSON(snap: snap)
        let body = "CURRENT TOP SUSPECT\n\(suspect)\n\n---\n\n" + buildStabilityDiagnosticBody(reason: "Manual stability report", snap: snap)
        GitHubIssueDraftStore.shared.openManual(
            rawTranscript: "stability report",
            context: body,
            defaultRepo: controller.defaultGitHubRepo
        )
        // Override title and pre-fill logs
        if let draft = GitHubIssueDraftStore.shared.currentDraft {
            draft.title = "[Stability] Manual Jarvis Diagnostic Report"
            draft.issueType = .task
            draft.severity = .medium
            draft.area = .macApp
            draft.logsTrace = recentBreadcrumbs()
        }
        controller.overlayManager.open(.githubIssue)
        Log.github.info("[GitHubIssueOverlay] opened source=manual_stability_report")
    }

    // MARK: - Idle audit

    private func runIdleAudit(snap: SelfMonitorSnapshot) async {
        let idleSeconds = await MainActor.run {
            idleSince.map { Date().timeIntervalSince($0) } ?? 0
        }
        guard idleSeconds > thresholds.idleAfterSeconds else { return }

        // Flag runaway subsystems
        let profiles = await MainActor.run { subsystemProfiles }
        for p in profiles where p.isRunaway {
            logger.warning("[RunawayDetector] subsystem=\(p.name) eventsPerMinute=\(String(format: "%.0f", p.eventsPerMinute)) expected<\(p.runawayThreshold) status=RUNAWAY")
        }

        // Log idle audit
        logger.info("[IdleAudit] idleSeconds=\(String(format: "%.0f", idleSeconds)) rss=\(snap.rssMemoryMB)MB cpu=\(String(format: "%.1f", snap.cpuPercent))% overlays=\(snap.activeOverlayCount) news=\(snap.newsJobsActive)")
        logger.info("[IdleAudit] listening=\(snap.isListening) speaking=\(snap.isSpeaking) daemon_reconnects=\(snap.daemonReconnectAttempts)")

        // CPU performance report every 10 samples during idle
        await MainActor.run {
            if let ctrl = controller, snap.cpuPercent > 10 {
                let top = topCPUSubsystem(snap: snap)
                logger.info("[Performance] cpu=\(String(format: "%.1f", snap.cpuPercent))% topSubsystem=\(top)")
            }
        }

        // Tell the IdleEnforcer to enforce if needed
        if let ctrl = controller { IdleEnforcer.shared.enforce(controller: ctrl, idleSeconds: idleSeconds) }
    }

    // MARK: - Subsystem profiles

    private func updateSubsystemProfiles(snap: SelfMonitorSnapshot) {
        // Build lightweight profile list for the profiler overlay
        let idle = snap.isIdle
        subsystemProfiles = [
            SubsystemProfile(
                name: "Wake Word",
                state: snap.wakeWordActive ? "active" : "idle",
                eventsPerMinute: Double(snap.wakeWordTriggersPerMinute),
                isExpectedIdle: false,   // wake word should always be active
                runawayThreshold: 20,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "STT",
                state: snap.sttSessionActive ? "active" : "idle",
                eventsPerMinute: snap.sttSessionActive ? 60 : 0,
                isExpectedIdle: idle && snap.sttSessionActive,
                runawayThreshold: 5,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "TTS",
                state: snap.ttsActive ? "active" : "idle",
                eventsPerMinute: snap.ttsActive ? 60 : 0,
                isExpectedIdle: idle && snap.ttsActive,
                runawayThreshold: 5,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "News / Proactivity",
                state: snap.newsJobsActive ? "active" : "idle",
                eventsPerMinute: snap.newsJobsActive ? 100 : 0,
                isExpectedIdle: idle && snap.newsJobsActive,
                runawayThreshold: 10,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "Daemon Bridge",
                state: snap.daemonReconnectAttempts > 0 ? "reconnecting" : "idle",
                eventsPerMinute: Double(snap.daemonReconnectAttempts * 12),  // per-sample × 12 = per-minute
                isExpectedIdle: false,
                runawayThreshold: 6,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "Camera",
                state: snap.cameraStreaming ? "streaming" : "idle",
                eventsPerMinute: snap.cameraStreaming ? 30 : 0,
                isExpectedIdle: idle && snap.cameraStreaming && snap.activeOverlayCount == 0,
                runawayThreshold: 5,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "Overlays",
                state: snap.activeOverlayCount > 0 ? "\(snap.activeOverlayCount) open" : "none",
                eventsPerMinute: 0,
                isExpectedIdle: false,
                runawayThreshold: 8,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "Ambient Context",
                state: snap.ambientSamplingActive ? "sampling" : "idle",
                eventsPerMinute: snap.ambientSamplingActive ? 2 : 0,
                isExpectedIdle: false,
                runawayThreshold: 20,
                lastActivityAt: nil
            ),
            SubsystemProfile(
                name: "Network",
                state: snap.networkRequestsPerMinute > 0 ? "active" : "idle",
                eventsPerMinute: Double(snap.networkRequestsPerMinute),
                isExpectedIdle: idle && snap.networkRequestsPerMinute > 10,
                runawayThreshold: 10,
                lastActivityAt: nil
            ),
        ]
    }

    // MARK: - Top CPU suspect (primary diagnostic output)

    /// Returns a structured suspect block that is always written FIRST in any
    /// diagnostic file, spoken by Jarvis on "why are you crashing", and shown
    /// at the top of the RuntimeProfiler overlay.
    func topSuspectJSON(snap: SelfMonitorSnapshot? = nil) -> String {
        let s = snap ?? latestSnapshot
        let (name, estimate, events, reason) = topSuspectDetails(snap: s)
        let body = """
        {
          "topSuspect": "\(name)",
          "cpuEstimate": \(String(format: "%.1f", estimate)),
          "eventsPerMinute": \(events),
          "reason": "\(reason)"
        }
        """
        logger.warning("[SelfMonitor] CURRENT TOP SUSPECT: \(name) cpu≈\(String(format: "%.1f", estimate))% — \(reason)")
        return body
    }

    /// Human-readable spoken summary for "why are you crashing" command.
    func spokenSuspectSummary() -> String {
        let (name, estimate, _, reason) = topSuspectDetails(snap: latestSnapshot)
        let mem = latestSnapshot?.rssMemoryMB ?? 0
        let cpu = latestSnapshot?.cpuPercent ?? 0
        return "Current top CPU suspect is \(name), estimated at \(String(format: "%.0f", estimate)) percent. Memory is \(mem) megabytes, total CPU is \(String(format: "%.0f", cpu)) percent. Reason: \(reason). I've opened the diagnostics overlay."
    }

    private func topSuspectDetails(snap: SelfMonitorSnapshot?) -> (String, Double, Int, String) {
        guard let s = snap else {
            return ("unknown", 0, 0, "No snapshot collected yet — wait 5 seconds and retry")
        }

        // Priority-ordered heuristic table
        // Orb render loop is now fixed (2fps at idle), but if this was collected
        // before the fix it would show as the top suspect
        if s.cpuPercent > 15 && s.isIdle && !s.newsJobsActive && !s.sttSessionActive {
            return ("OrbAnimationLoop",
                    s.cpuPercent * 0.55, 1800,
                    "LightweightOrbView TimelineView at 30fps in passive/idle state. Every 33ms: sin(), gradients, shadows, arcs across 6 Canvas layers. PRIMARY FIX: paused in .idle, 2fps in .passive")
        }
        if s.newsJobsActive && s.isIdle {
            return ("NewsRefreshScheduler",
                    s.cpuPercent * 0.45, Int(s.networkRequestsPerMinute * 20),
                    "News processing \(s.networkRequestsPerMinute) network requests/min while idle. Background feed refresh running when no news overlay is open")
        }
        if s.daemonReconnectAttempts >= 3 {
            return ("DaemonBridge",
                    s.cpuPercent * 0.30, s.daemonReconnectAttempts * 12,
                    "Daemon reconnect loop: \(s.daemonReconnectAttempts) consecutive failures. Exponential backoff should be running but CPU is high — check DaemonAppBridge.scheduleReconnect()")
        }
        if s.sttSessionActive && s.isIdle {
            return ("SpeechRecognizer",
                    s.cpuPercent * 0.40, 60,
                    "STT session active while user is idle. AVAudioEngine tap + Apple Speech neural network inference running unnecessarily")
        }
        if s.cameraStreaming && s.activeOverlayCount == 0 {
            return ("CameraStream",
                    s.cpuPercent * 0.35, 60,
                    "Camera streaming with no camera overlay open. Stream should stop when overlay closes")
        }
        if s.ambientSamplingActive && s.isIdle && s.cpuPercent > 10 {
            return ("AmbientContextEngine",
                    s.cpuPercent * 0.25, 12,
            "AmbientContextEngine sampling screen/windows every 30s. CGWindowListCopyWindowInfo is expensive. IdleEnforcer should slow this to 120s")
        }
        if s.logsPerMinute > 200 {
            return ("LogSpam",
                    s.cpuPercent * 0.20, s.logsPerMinute,
                    "Log spam: \(s.logsPerMinute) lines/min. Repeated logging from a loop is both CPU and I/O intensive")
        }
        if s.wakeWordTriggersPerMinute > 10 {
            return ("WakeWordService",
                    s.cpuPercent * 0.30, s.wakeWordTriggersPerMinute,
                    "Wake word triggering \(s.wakeWordTriggersPerMinute) times/min. Possible false triggers or audio loop")
        }
        // Generic: threads × task load
        if s.threadCount > 60 {
            return ("ThreadOverload",
                    s.cpuPercent, s.threadCount * 10,
                    "\(s.threadCount) threads active. Normal idle should be 20-35. Check for runaway Task spawning")
        }
        return ("Unknown",
                s.cpuPercent, 0,
                "CPU \(String(format: "%.1f", s.cpuPercent))% at idle — no obvious single subsystem. Run Instruments Time Profiler for ground truth")
    }

    /// Public accessor used by RuntimeProfilerView.
    func topSuspectDetails_public(snap: SelfMonitorSnapshot) -> (String, Double, Int, String) {
        topSuspectDetails(snap: snap)
    }

    private func topCPUSubsystem(snap: SelfMonitorSnapshot) -> String {
        topSuspectDetails(snap: snap).0
    }

    // MARK: - Diagnostic bundle

    private func writeDiagnosticBundle(
        reason: String,
        subsystem: String,
        snap: SelfMonitorSnapshot
    ) async {
        let ctrl = await MainActor.run { controller }
        let daemonStatus = await MainActor.run {
            switch DaemonManager.shared.status {
            case .running: return "running"
            case .stopped: return "stopped"
            case .crashed: return "crashed"
            default: return "unknown"
            }
        }
        let brainStatus = await MainActor.run {
            ctrl?.state.brainDegraded == true ? "degraded" : "ok"
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        let recentSnaps = await MainActor.run { Array(snapshots.suffix(180)) }
        let subsystemStates = await MainActor.run {
            subsystemProfiles.reduce(into: [:]) { dict, p in dict[p.name] = p.state }
        }

        let bundle = DiagnosticBundle(
            triggeredAt: Date(),
            triggerReason: reason,
            triggerSubsystem: subsystem,
            recentSnapshots: recentSnaps,
            subsystemStates: subsystemStates,
            recentLogs: recentBreadcrumbs(),
            environment: DiagnosticBundle.DiagnosticEnvironment(
                appVersion: version,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                daemonStatus: daemonStatus,
                brainStatus: brainStatus,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )

        let dir = Self.diagnosticsDir
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("diagnostic_\(ts).json")

        // Write TOP SUSPECT as a standalone file so it's always readable even if
        // the JSON bundle is large or partially written.
        let suspectFile = dir.appendingPathComponent("top_suspect_\(ts).json")
        let suspectJSON = await MainActor.run { topSuspectJSON(snap: snap) }
        try? suspectJSON.data(using: .utf8)?.write(to: suspectFile, options: .atomic)

        if let data = try? JSONEncoder().encode(bundle) {
            // Prepend the top suspect block to the bundle for easy reading
            var fullOutput = "CURRENT TOP SUSPECT\n\(suspectJSON)\n\n---\n\n"
            if let bundleStr = String(data: data, encoding: .utf8) { fullOutput += bundleStr }
            try? fullOutput.data(using: .utf8)?.write(to: file, options: .atomic)
            Log.app.info("[SelfMonitor] diagnostic bundle written to \(file.lastPathComponent)")
        }
    }

    // MARK: - Body builder

    private func buildStabilityDiagnosticBody(reason: String, snap: SelfMonitorSnapshot) -> String {
        let profiles = subsystemProfiles
        var lines: [String] = []

        lines.append("Jarvis detected a likely runaway stability issue before crash.")
        lines.append("")
        lines.append("**Trigger:** \(reason)")
        lines.append("")
        lines.append("**Metrics at trigger:**")
        lines.append("- Memory (RSS): \(snap.rssMemoryMB) MB")
        lines.append("- CPU: \(String(format: "%.1f", snap.cpuPercent))%")
        lines.append("- Threads: \(snap.threadCount)")
        lines.append("- File descriptors: \(snap.fdCount)")
        lines.append("- Active overlays: \(snap.activeOverlayCount)")
        lines.append("- Daemon reconnects: \(snap.daemonReconnectAttempts)")
        lines.append("- Log lines/min: \(snap.logsPerMinute)")
        lines.append("- Network req/min: \(snap.networkRequestsPerMinute)")
        lines.append("")
        lines.append("**Active subsystems:**")
        for p in profiles {
            lines.append("- \(p.name): \(p.statusIcon) (\(String(format: "%.0f", p.eventsPerMinute)) events/min)")
        }
        lines.append("")
        lines.append("**Flags:**")
        lines.append("- STT active while idle: \(snap.isIdle && snap.sttSessionActive)")
        lines.append("- News active while idle: \(snap.isIdle && snap.newsJobsActive)")
        lines.append("- Camera active with no overlays: \(snap.cameraStreaming && snap.activeOverlayCount == 0)")
        lines.append("- Daemon reconnect loop: \(snap.daemonReconnectAttempts >= 3)")
        lines.append("")
        lines.append("**Suspected cause:** \(topCPUSubsystem(snap: snap))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Recent logs

    private func recentBreadcrumbs() -> String {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.temporaryDirectory
        let url = base.appendingPathComponent("JarvisMac/crash-breadcrumbs.log")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "(logs unavailable)" }
        // Last 200 lines
        let lines = content.components(separatedBy: "\n")
        return lines.suffix(200).joined(separator: "\n")
    }

    private func buildEmptySnapshot() -> SelfMonitorSnapshot {
        SelfMonitorSnapshot(
            timestamp: Date(), rssMemoryMB: 0, cpuPercent: 0,
            threadCount: 0, fdCount: -1,
            isListening: false, isSpeaking: false,
            wakeWordActive: false, sttSessionActive: false, ttsActive: false,
            activeOverlayCount: 0, cameraStreaming: false,
            newsJobsActive: false, proactivityActive: false,
            daemonReconnectAttempts: 0, ambientSamplingActive: false,
            logsPerMinute: 0, networkRequestsPerMinute: 0,
            wakeWordTriggersPerMinute: 0
        )
    }

    // MARK: - System metric helpers

    /// Process CPU usage as a percentage (0-100).
    /// Uses mach thread_basic_info to accumulate user+system CPU ticks.
    static func processCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threads),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var totalCPU: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let res = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if res == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return totalCPU
    }

    /// Active thread count for this process.
    static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &count) == KERN_SUCCESS,
              let list = threadList else { return 0 }
        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: list),
                      vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        return Int(count)
    }

    /// Open file descriptor count via getrlimit + scan.
    static func openFileDescriptorCount() -> Int {
        var rl = rlimit()
        getrlimit(RLIMIT_NOFILE, &rl)
        var open = 0
        let maxCheck = min(Int(rl.rlim_cur), 4096)
        for fd in Int32(0)..<Int32(maxCheck) {
            if fcntl(fd, F_GETFD) != -1 { open += 1 }
        }
        return open
    }
}

// MARK: - JarvisController extension for SelfMonitor access

extension JarvisController {
    /// Close all overlays except those in the exclusion list.
    func closeAllOverlaysExceptStability() {
        overlayManager.closeAll(except: [.githubIssue])
    }
}

// MARK: - OverlayManager.closeAll

extension OverlayManager {
    /// Forcibly close all overlays except those in the exclusion list.
    func closeAll(except keep: [OverlayKind] = []) {
        let toClose = overlays.map { $0.kind }.filter { !keep.contains($0) }
        for kind in toClose { _ = close(kind) }
    }
}

// NOTE: NewsRefreshScheduler.isRefreshing and suspendBackgroundTick/resumeBackgroundTick
// are defined in NewsRefreshScheduler.swift directly.
