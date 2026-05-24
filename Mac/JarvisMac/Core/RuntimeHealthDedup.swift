import Foundation
import os

// MARK: - RuntimeHealthDedup

/// Prevents RuntimeHealthMonitor from emitting repeated alerts for the same
/// subsystem failure within a cooldown window. Also scores severity so only
/// genuinely impactful issues surface as spoken interruptions.
@MainActor
final class RuntimeHealthDedup {

    static let shared = RuntimeHealthDedup()

    private let log = Logger(subsystem: "com.jarvis", category: "runtime.health.dedup")

    // MARK: - Severity

    enum HealthSeverity: Int, Comparable {
        case info     = 0
        case warning  = 1
        case error    = 2
        case critical = 3

        static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct HealthEvent {
        let subsystemId: String
        let detail: String
        let severity: HealthSeverity
        let timestamp: Date
        var key: String { "\(subsystemId):\(detail.prefix(40))" }
    }

    // MARK: - Severity Scoring

    struct SeverityScore {
        var subsystem: String
        var repeatedFailures: Int = 0
        var importance: Double          // 0–1 (conversation=1.0, brain=0.9, etc.)
        var userImpact: Double = 0.5
        var isRecovered: Bool = false

        var overallScore: Double {
            guard !isRecovered else { return 0 }
            let repFactor = min(1.0, Double(repeatedFailures) / 5.0)
            return importance * 0.4 + userImpact * 0.3 + repFactor * 0.3
        }

        var shouldAlert: Bool { overallScore > 0.5 }
    }

    // MARK: - Configuration

    var alertCooldownSeconds: Double = 600  // 10 min between same-event alerts

    // MARK: - State

    private var alertedAt:       [String: Date]            = [:]
    private var subsystemScores: [String: SeverityScore]   = [:]
    private var failureCounts:   [String: Int]             = [:]

    private let importanceMap: [String: Double] = [
        "conversation": 1.0,
        "audio":        0.95,
        "tts":          0.90,
        "stt":          0.90,
        "brain":        0.85,
        "llm":          0.80,
        "ha":           0.65,
        "network":      0.60,
        "vision":       0.50,
        "system":       0.45,
    ]

    // MARK: - Evaluate

    /// Returns true if the event should trigger a user-facing alert.
    @discardableResult
    func evaluate(event: HealthEvent) -> Bool {
        let key = event.key
        failureCounts[key, default: 0] += 1

        var score = subsystemScores[event.subsystemId] ?? SeverityScore(
            subsystem: event.subsystemId,
            importance: importanceMap[event.subsystemId] ?? 0.5
        )
        score.repeatedFailures = failureCounts[key] ?? 1
        score.isRecovered = false
        subsystemScores[event.subsystemId] = score

        // Dedup: suppress if alerted recently for the same key
        if let last = alertedAt[key] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < alertCooldownSeconds {
                log.debug("health_dedup key=\(key) elapsed=\(Int(elapsed))s")
                return false
            }
        }

        guard score.shouldAlert else { return false }

        alertedAt[key] = Date()
        log.warning("health_alert subsystem=\(event.subsystemId) severity=\(event.severity.rawValue) failures=\(score.repeatedFailures)")
        return true
    }

    func recordRecovery(subsystem: String) {
        if var score = subsystemScores[subsystem] {
            score.isRecovered = true
            score.repeatedFailures = 0
            subsystemScores[subsystem] = score
        }
        alertedAt = alertedAt.filter { !$0.key.hasPrefix(subsystem + ":") }
        log.info("health_recovery subsystem=\(subsystem)")
    }

    func scoreFor(subsystem: String) -> SeverityScore? {
        subsystemScores[subsystem]
    }

    func severitySummary() -> String {
        let active = subsystemScores.values
            .filter { !$0.isRecovered && $0.repeatedFailures > 0 }
            .sorted { $0.overallScore > $1.overallScore }
        guard !active.isEmpty else { return "All subsystems healthy" }
        return active.prefix(5).map {
            "\($0.subsystem): \(String(format:"%.0f", $0.overallScore * 100))% severity, \($0.repeatedFailures) failures"
        }.joined(separator: "; ")
    }
}
