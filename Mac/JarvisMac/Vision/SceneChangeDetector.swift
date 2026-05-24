import Foundation
import os

// MARK: - SceneChangeKind

enum SceneChangeKind: String {
    case presenceAcquired  = "presence_acquired"
    case presenceLost      = "presence_lost"
    case significantMotion = "motion"
    case lightingChange    = "lighting"
}

// MARK: - SceneChange

struct SceneChange {
    let kind: SceneChangeKind
    let confidence: Double
    let description: String
    let detectedAt: Date
}

// MARK: - SceneChangeDetector

/// Event-driven scene change detector that bridges camera pipeline results to
/// `PersistentVisionContext`.
///
/// **Design goals:**
/// - Event-driven: only updates `PersistentVisionContext` when state actually changes.
/// - No direct camera ownership — receives presence readings via `reportPresence()`,
///   which JarvisController calls when it has camera data.
/// - Hysteresis: requires N consecutive consistent readings before committing
///   a state change, to prevent flip-flopping.
@MainActor
final class SceneChangeDetector {

    static let shared = SceneChangeDetector()

    private let log = Logger(subsystem: "com.jarvis", category: "vision.scene")

    // MARK: - Configuration

    var presenceHysteresisCount: Int = 3   // frames before committing state change
    var changeDebounceSeconds: Double = 3.0

    // MARK: - State

    private(set) var lastChange: SceneChange?
    private(set) var changeHistory: [SceneChange] = []
    private var lastChangeTime: Date?
    private var consecutivePresenceFrames: Int = 0
    private var consecutiveAbsenceFrames: Int = 0

    // MARK: - Feed presence data (called by JarvisController or camera delegates)

    /// Report a camera-derived presence reading.
    /// - Parameters:
    ///   - isPresent: whether a person was detected
    ///   - confidence: detection confidence [0.0–1.0]
    func reportPresence(isPresent: Bool, confidence: Double) {
        let ctx = PersistentVisionContext.shared

        if isPresent {
            consecutivePresenceFrames += 1
            consecutiveAbsenceFrames = 0
        } else {
            consecutiveAbsenceFrames += 1
            consecutivePresenceFrames = 0
        }

        // Use VisionEfficiencyController's adaptive confidence threshold for committing
        let vec = VisionEfficiencyController.shared
        let candidateKind: UserPresenceKind = isPresent ? .present : .away
        let consecutiveForCandidate = isPresent ? consecutivePresenceFrames : consecutiveAbsenceFrames
        let canCommit = vec.shouldCommitPresenceChange(
            from: ctx.presenceKind, to: candidateKind,
            confidence: confidence, consecutiveFrames: consecutiveForCandidate
        )
        if consecutivePresenceFrames >= presenceHysteresisCount && ctx.presenceKind != .present && (canCommit || consecutivePresenceFrames >= presenceHysteresisCount) {
            let change = SceneChange(kind: .presenceAcquired, confidence: confidence,
                                     description: "user detected at desk", detectedAt: Date())
            commitChange(change)
            ctx.updatePresence(.present, confidence: confidence)
            vec.recordSignificantChange()

        } else if consecutiveAbsenceFrames >= presenceHysteresisCount && ctx.presenceKind == .present && (canCommit || consecutiveAbsenceFrames >= presenceHysteresisCount) {
            let change = SceneChange(kind: .presenceLost, confidence: 1.0 - confidence,
                                     description: "user left desk", detectedAt: Date())
            commitChange(change)
            ctx.updatePresence(.away, confidence: 1.0 - confidence)
            vec.recordSignificantChange()
        }
    }

    /// Report that the camera is no longer available.
    func reportCameraUnavailable() {
        PersistentVisionContext.shared.markCameraUnavailable()
        consecutivePresenceFrames = 0
        consecutiveAbsenceFrames = 0
    }

    // MARK: - Feed motion data

    func reportSignificantMotion(delta: Double) {
        guard delta > 0.4 else { return }
        let change = SceneChange(kind: .significantMotion, confidence: delta,
                                 description: "significant motion detected", detectedAt: Date())
        commitChange(change)
        SystemBus.shared.publish(SceneChangedEvent(kind: change.kind.rawValue, confidence: delta))
    }

    // MARK: - History

    private func commitChange(_ change: SceneChange) {
        if let last = lastChangeTime,
           Date().timeIntervalSince(last) < changeDebounceSeconds { return }

        lastChange = change
        lastChangeTime = Date()
        changeHistory.append(change)
        if changeHistory.count > 50 { changeHistory.removeFirst() }

        log.debug("Scene change: \(change.kind.rawValue) confidence=\(String(format: "%.2f", change.confidence))")
        SystemBus.shared.publish(SceneChangedEvent(kind: change.kind.rawValue, confidence: change.confidence))
    }

    var diagnosticSummary: String {
        let ctx = PersistentVisionContext.shared
        return "presence=\(ctx.presenceKind.rawValue) changes=\(changeHistory.count) last=\(lastChange?.kind.rawValue ?? "none")"
    }
}

// MARK: - SceneChangedEvent

struct SceneChangedEvent: SystemEvent {
    let kind: String
    let confidence: Double
    let id = UUID()
    let timestamp = Date()
    var source: SystemEventSource    { .ambient }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .low }
    var correlationID: UUID?          { nil }
}
