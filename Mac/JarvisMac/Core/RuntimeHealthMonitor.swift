import Foundation

// MARK: - FailurePattern

private struct FailureRecord {
    let timestamp: Date
    let subsystem: RuntimeHealthMonitor.Subsystem
    let detail: String?
}

// MARK: - RuntimeHealthMonitor

/// Tracks repeated failures across STT, TTS, LLM, and HA subsystems.
/// When a failure threshold is crossed it surfaces a `ProactiveEvent` so the
/// user knows the system is degraded without having to ask.
///
/// Distinct from `RuntimeCoordinator` (which manages subsystem lifecycle) —
/// this is specifically about pattern detection and user notification.
@MainActor
final class RuntimeHealthMonitor {

    static let shared = RuntimeHealthMonitor()

    enum Subsystem: String {
        case stt = "speech_recognition"
        case tts = "text_to_speech"
        case llm = "language_model"
        case homeAssistant = "home_assistant"
        case network = "network"
    }

    // MARK: - Configuration

    /// Number of failures within `windowSeconds` that triggers an alert.
    var failureThreshold: Int = 3
    var windowSeconds: Double = 120

    /// Minimum interval between health alerts for the same subsystem.
    var alertCooldownSeconds: Double = 300

    // MARK: - State

    private var records: [FailureRecord] = []
    private var lastAlertTime: [Subsystem: Date] = [:]
    private var suppressedSubsystems: Set<Subsystem> = []

    // MARK: - Recording

    /// Record a failure event. Triggers an alert if threshold is crossed.
    func recordFailure(_ subsystem: Subsystem, detail: String? = nil) {
        let record = FailureRecord(timestamp: Date(), subsystem: subsystem, detail: detail)
        records.append(record)
        pruneOldRecords()
        checkThreshold(for: subsystem)
    }

    /// Record a recovery. Clears suppression so alerts can fire again.
    func recordRecovery(_ subsystem: Subsystem) {
        suppressedSubsystems.remove(subsystem)
        lastAlertTime.removeValue(forKey: subsystem)
    }

    // MARK: - Threshold check

    private func checkThreshold(for subsystem: Subsystem) {
        guard !suppressedSubsystems.contains(subsystem) else { return }

        let windowStart = Date().addingTimeInterval(-windowSeconds)
        let recentFailures = records.filter {
            $0.subsystem == subsystem && $0.timestamp > windowStart
        }

        guard recentFailures.count >= failureThreshold else { return }

        // Cooldown check
        if let lastAlert = lastAlertTime[subsystem],
           Date().timeIntervalSince(lastAlert) < alertCooldownSeconds { return }

        lastAlertTime[subsystem] = Date()
        emitAlert(subsystem: subsystem, failureCount: recentFailures.count,
                  latestDetail: recentFailures.last?.detail)
    }

    private func emitAlert(subsystem: Subsystem, failureCount: Int, latestDetail: String?) {
        // Dedup check: RuntimeHealthDedup prevents repeated alerts for the same issue
        let dedupEvent = RuntimeHealthDedup.HealthEvent(
            subsystemId: subsystem.rawValue,
            detail: latestDetail ?? "repeated_failure",
            severity: failureCount >= 5 ? .critical : .error,
            timestamp: Date()
        )
        guard RuntimeHealthDedup.shared.evaluate(event: dedupEvent) else { return }

        let (title, body, spoken) = alertText(subsystem: subsystem,
                                              failureCount: failureCount,
                                              detail: latestDetail)
        let signal = ProactivitySignal(
            source: .system,
            title: title,
            body: body,
            category: "runtime_health.\(subsystem.rawValue)",
            priority: .high,
            dedupeKey: "health.\(subsystem.rawValue).\(Int(Date().timeIntervalSince1970 / alertCooldownSeconds))",
            spokenText: spoken,
            requiresAttention: true
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
    }

    private func alertText(subsystem: Subsystem,
                           failureCount: Int,
                           detail: String?) -> (title: String, body: String, spoken: String) {
        switch subsystem {
        case .stt:
            return (
                "Speech recognition issues",
                "\(failureCount) failures in \(Int(windowSeconds / 60)) minutes",
                "I'm having trouble understanding you — speech recognition has failed \(failureCount) times. You might try speaking closer to the microphone."
            )
        case .tts:
            return (
                "Voice synthesis issues",
                "\(failureCount) TTS failures detected",
                "My text-to-speech is having issues. I may not be able to speak responses reliably right now."
            )
        case .llm:
            return (
                "AI model unreachable",
                detail ?? "LLM endpoint not responding",
                "I can't reach the AI model right now, so complex requests won't work. Basic commands still work."
            )
        case .homeAssistant:
            return (
                "Home Assistant disconnected",
                "Lost WebSocket connection",
                "I've lost my connection to Home Assistant. Smart home commands may not work until reconnected."
            )
        case .network:
            return (
                "Network issues",
                "\(failureCount) network failures",
                "I'm seeing network connectivity problems. Some features that need the internet may not work."
            )
        }
    }

    // MARK: - Diagnostics

    var recentFailureSummary: String {
        pruneOldRecords()
        if records.isEmpty { return "No recent failures" }
        let grouped = Dictionary(grouping: records, by: { $0.subsystem.rawValue })
        return grouped.map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
    }

    private func pruneOldRecords() {
        let cutoff = Date().addingTimeInterval(-max(windowSeconds, alertCooldownSeconds))
        records.removeAll { $0.timestamp < cutoff }
    }
}
