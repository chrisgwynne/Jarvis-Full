import Foundation
import os

// MARK: - StreamingRecoveryLayer

/// Handles edge cases in streaming conversation that would otherwise wedge TTS
/// or produce confused responses. Integrated into StreamingConversationEngine
/// for double-interruption, token-stall, and rapid-correction scenarios.
@MainActor
final class StreamingRecoveryLayer {

    static let shared = StreamingRecoveryLayer()

    private let log = Logger(subsystem: "com.jarvis", category: "streaming.recovery")

    // MARK: - Types

    enum RecoveryReason: String {
        case interruptionDuringCancellation
        case overlappingPivot
        case emptyStream
        case tokenStall
        case ttsUnderrun
        case rapidCorrection
        case doubleInterruption
    }

    enum RecoveryAction {
        case resumeFromSpoken
        case restartWithContext
        case silentDiscard
        case fallbackSingle(String)
    }

    // MARK: - State

    private var lastRecoveryAt: Date?
    private(set) var recoveryCount: Int = 0
    private(set) var lastReason: RecoveryReason?

    // MARK: - Handle

    func handleEdgeCase(
        _ reason: RecoveryReason,
        engine: StreamingConversationEngine,
        planner: ConversationalPivotPlanner
    ) -> RecoveryAction {
        let now = Date()
        // Two recoveries within 2 seconds = rapid oscillation
        let isRapidRepeat = lastRecoveryAt.map { now.timeIntervalSince($0) < 2.0 } ?? false
        recoveryCount += 1
        lastRecoveryAt = now
        lastReason = reason
        log.warning("streaming_recovery reason=\(reason.rawValue) rapid=\(isRapidRepeat) total=\(self.recoveryCount)")

        switch reason {
        case .interruptionDuringCancellation, .doubleInterruption:
            engine.cancelStream()
            planner.clearIfIdle()
            return .silentDiscard

        case .overlappingPivot:
            engine.cancelStream()
            return isRapidRepeat ? .silentDiscard : .restartWithContext

        case .emptyStream:
            return .fallbackSingle("Sorry, I lost my train of thought.")

        case .tokenStall:
            if let lastSpoken = planner.spokenClauses.last {
                return .fallbackSingle("Anyway — \(lastSpoken)")
            }
            return .silentDiscard

        case .ttsUnderrun:
            return .resumeFromSpoken

        case .rapidCorrection:
            engine.cancelStream()
            return .restartWithContext
        }
    }

    func clearIfSafe() {
        guard let last = lastRecoveryAt,
              Date().timeIntervalSince(last) > 30 else { return }
        recoveryCount = 0
        lastReason = nil
        lastRecoveryAt = nil
    }

    var recoveryReport: String {
        "StreamingRecovery: count=\(recoveryCount) lastReason=\(lastReason?.rawValue ?? "-") lastAt=\(lastRecoveryAt.map { $0.formatted() } ?? "-")"
    }
}
