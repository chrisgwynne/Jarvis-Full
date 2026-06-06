import Foundation
import Darwin.Mach

// MARK: - SelfMonitorSnapshot

/// Point-in-time metrics sample taken every 5 seconds.
struct SelfMonitorSnapshot: Codable {

    let timestamp:  Date

    // ── System ────────────────────────────────────────────────────────
    let rssMemoryMB:  Int       // resident set size
    let cpuPercent:   Double    // 0–100 process CPU
    let threadCount:  Int
    let fdCount:      Int       // open file descriptors (-1 = unavailable)

    // ── Conversation / audio ──────────────────────────────────────────
    let isListening:        Bool
    let isSpeaking:         Bool
    let wakeWordActive:     Bool
    let sttSessionActive:   Bool
    let ttsActive:          Bool

    // ── Subsystem activity ────────────────────────────────────────────
    let activeOverlayCount: Int
    let cameraStreaming:     Bool
    let newsJobsActive:      Bool
    let proactivityActive:   Bool
    let daemonReconnectAttempts: Int
    let ambientSamplingActive:   Bool

    // ── Rolling event counters (per sample period) ────────────────────
    let logsPerMinute:       Int
    let networkRequestsPerMinute: Int
    let wakeWordTriggersPerMinute: Int

    // ── Computed ──────────────────────────────────────────────────────
    var isIdle: Bool {
        !isListening && !isSpeaking && !sttSessionActive && !ttsActive && activeOverlayCount == 0
    }
}

// MARK: - SubsystemProfile

/// Lightweight self-reported state from each subsystem for the profiler view.
struct SubsystemProfile {
    let name: String
    let state: String          // "idle", "active", "error", etc.
    let eventsPerMinute: Double
    let isExpectedIdle: Bool   // true when subsystem should be quiet but isn't
    var isRunaway: Bool { isExpectedIdle && eventsPerMinute > runawayThreshold }
    let runawayThreshold: Double
    let lastActivityAt: Date?

    var statusIcon: String {
        if isRunaway              { return "⚠️ RUNAWAY" }
        if state == "active"      { return "🟢 active" }
        if state == "error"       { return "🔴 error" }
        return "⚪ idle"
    }
}

// MARK: - WatchdogThresholds

struct WatchdogThresholds {
    /// RSS above this fires a warning.
    var maxMemoryMB: Int = 1_500

    /// Continuous memory growth for this many samples (5s each = 10 min) fires growth alert.
    var memoryGrowthSamples: Int = 120

    /// CPU above this % while idle fires a warning.
    var idleCPUPercent: Double = 20.0

    /// How many seconds of inactivity counts as "idle".
    var idleAfterSeconds: TimeInterval = 60.0

    /// CPU above this for this many consecutive idle samples fires the watchdog.
    var cpuWatchSamples: Int = 24   // 24 × 5s = 2 min

    /// Daemon reconnect attempts per minute above this is a loop.
    var daemonReconnectLoopPerMin: Int = 3

    /// More than this many overlays open simultaneously.
    var maxOverlayCount: Int = 6

    /// Log lines per minute above this is spam.
    var logSpamPerMinute: Int = 500
}

// MARK: - DiagnosticBundle

/// Full diagnostic package written to disk when a threshold fires.
struct DiagnosticBundle: Codable {
    let triggeredAt: Date
    let triggerReason: String
    let triggerSubsystem: String
    let recentSnapshots: [SelfMonitorSnapshot]
    let subsystemStates: [String: String]
    let recentLogs: String
    let environment: DiagnosticEnvironment

    struct DiagnosticEnvironment: Codable {
        let appVersion: String
        let macOSVersion: String
        let daemonStatus: String
        let brainStatus: String
        let uptimeSeconds: Double
        let processID: Int32
    }
}
