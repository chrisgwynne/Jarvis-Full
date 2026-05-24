import Foundation
import CoreGraphics

// MARK: - ThreatClassifier

/// Heuristic threat classification for tracked targets.
///
/// Each call to `classify(targets:)` returns an updated copy of the targets array
/// with `threatLevel` adjusted according to behavioural signals (lingering, velocity,
/// concealment, surveillance equipment). Scene-level summary is available via
/// `sceneThreatLevel` and `threatReason`.
///
/// Threat can escalate immediately but only deescalates after 15 consecutive frames
/// at the lower proposed level (hysteresis).
@MainActor final class ThreatClassifier {

    // MARK: Configuration

    /// Duration (seconds) a person must be continuously visible before they are
    /// considered suspicious.
    var lingerThreshold: TimeInterval = 30.0

    /// Velocity magnitude (normalized units per second) above which a target is
    /// flagged as suspicious due to rapid movement.
    var rapidVelocityThreshold: CGFloat = 0.4

    /// Ratio of face bounding area to body bounding area below which the tracker
    /// considers the face concealed (e.g. mask, hood, cap pulled low).
    /// Only applied when the person has been visible long enough to be meaningful.
    var concealmentRatio: CGFloat = 0.05

    // MARK: Scene-level state (observable by caller)

    private(set) var sceneThreatLevel: ThreatLevel = .normal
    private(set) var threatReason: String = ""

    // MARK: Per-target hysteresis state

    private struct ThreatHistory {
        /// The most recently committed (post-hysteresis) threat level.
        var level: ThreatLevel
        /// How many consecutive frames the proposed level has been lower than `level`.
        var framesAtLowerLevel: Int
        /// Timestamp of the last escalation (unused beyond diagnostics for now).
        var lastEscalation: Date
    }

    private var threatHistory: [UUID: ThreatHistory] = [:]

    /// Frames the proposed level must be lower before deescalation is committed.
    private let deescalationFrames: Int = 15

    // MARK: Public API

    /// Run one classification pass over all currently tracked targets.
    ///
    /// - Parameter targets: The latest snapshot from `ObjectTracker.activeTargets`.
    /// - Returns: A new array of targets with updated `threatLevel` fields.
    func classify(targets: [TrackedTarget]) -> [TrackedTarget] {
        var updated = targets.map { target -> TrackedTarget in
            var t = target
            let proposed = assessThreat(target: t, allTargets: targets)
            t.threatLevel = applyHysteresis(targetID: t.id, proposed: proposed)
            return t
        }

        updateSceneThreat(targets: updated)

        // Prune hysteresis state for targets that no longer exist.
        let liveIDs = Set(targets.map { $0.id })
        threatHistory = threatHistory.filter { liveIDs.contains($0.key) }

        return updated
    }

    // MARK: Private — per-target assessment

    /// Compute the raw (pre-hysteresis) threat level for a single target.
    private func assessThreat(target: TrackedTarget, allTargets: [TrackedTarget]) -> ThreatLevel {
        // Rule 1: Surveillance camera → immediately suspicious regardless of other signals.
        if target.cls == .surveillanceCamera {
            return .suspicious
        }

        // Threat accumulator — we escalate to the worst triggered rule.
        var proposedThreat = target.cls.defaultThreat

        // Rule 2 & 3: Lingering person.
        if target.cls == .person || target.cls == .face {
            let visible = target.timeVisible

            if visible > lingerThreshold * 3 {
                // Lingered three times as long as the base threshold → full alert.
                proposedThreat = max(proposedThreat, .alert)
            } else if visible > lingerThreshold {
                proposedThreat = max(proposedThreat, .suspicious)
            }
        }

        // Rule 4: Rapid velocity — applies to any class.
        let speed = sqrt(target.velocity.dx * target.velocity.dx +
                         target.velocity.dy * target.velocity.dy)
        if speed > rapidVelocityThreshold {
            proposedThreat = max(proposedThreat, .suspicious)
        }

        // Rule 5: Face concealment — person visible with no corresponding face detection.
        // We look for whether the active targets include a face bbox whose area is at least
        // `concealmentRatio` of this person's bbox area. If the person has been visible long
        // enough (>10 s) and no face is visible, flag as suspicious.
        if target.cls == .person && target.timeVisible > 10.0 {
            let personArea = target.bounds.width * target.bounds.height
            guard personArea > 0 else { return proposedThreat }

            // Is there a face target on the same camera that spatially overlaps this person?
            let facePresent = allTargets.contains { faceTarget in
                guard faceTarget.cls == .face,
                      faceTarget.cameraFeedID == target.cameraFeedID,
                      !faceTarget.isGhost else { return false }
                // Face must overlap the person's bounding rect.
                let intersection = faceTarget.bounds.intersection(target.bounds)
                guard !intersection.isNull && !intersection.isEmpty else { return false }
                let faceArea = faceTarget.bounds.width * faceTarget.bounds.height
                return faceArea / personArea >= concealmentRatio
            }

            if !facePresent {
                proposedThreat = max(proposedThreat, .suspicious)
            }
        }

        return proposedThreat
    }

    // MARK: Private — scene-level summary

    /// Derive the worst threat across all non-ghost targets and update `sceneThreatLevel`.
    private func updateSceneThreat(targets: [TrackedTarget]) {
        let activeTargets = targets.filter { !$0.isGhost }

        guard let worst = activeTargets.max(by: { $0.threatLevel < $1.threatLevel }) else {
            sceneThreatLevel = .normal
            threatReason = ""
            return
        }

        sceneThreatLevel = worst.threatLevel

        switch worst.threatLevel {
        case .normal:
            threatReason = ""
        case .suspicious:
            threatReason = buildReason(for: worst, allTargets: activeTargets)
        case .alert:
            threatReason = buildReason(for: worst, allTargets: activeTargets)
        }
    }

    /// Build a human-readable reason string for the given target's threat level.
    private func buildReason(for target: TrackedTarget, allTargets: [TrackedTarget]) -> String {
        if target.cls == .surveillanceCamera {
            return "Surveillance camera detected (\(target.trackLabel))"
        }

        let speed = sqrt(target.velocity.dx * target.velocity.dx +
                         target.velocity.dy * target.velocity.dy)
        let visible = target.timeVisible

        if visible > lingerThreshold * 3 {
            let mins = Int(visible / 60)
            let secs = Int(visible) % 60
            let timeStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
            return "\(target.trackLabel) lingering for \(timeStr)"
        }

        if speed > rapidVelocityThreshold {
            return "\(target.trackLabel) moving rapidly"
        }

        if visible > lingerThreshold {
            let secs = Int(visible)
            return "\(target.trackLabel) visible for \(secs)s"
        }

        return "\(target.trackLabel) flagged as \(target.threatLevel.systemLabel.lowercased())"
    }

    // MARK: Private — hysteresis

    /// Apply temporal hysteresis so threat only deescalates after `deescalationFrames`
    /// consecutive frames at the lower level.
    ///
    /// Escalation is always immediate.
    private func applyHysteresis(targetID: UUID, proposed: ThreatLevel) -> ThreatLevel {
        guard var history = threatHistory[targetID] else {
            // First time we see this target — commit proposed level immediately.
            threatHistory[targetID] = ThreatHistory(
                level: proposed,
                framesAtLowerLevel: 0,
                lastEscalation: proposed > .normal ? Date() : Date.distantPast
            )
            return proposed
        }

        if proposed >= history.level {
            // Escalation or same level — apply immediately.
            if proposed > history.level {
                history.lastEscalation = Date()
            }
            history.level = proposed
            history.framesAtLowerLevel = 0
        } else {
            // Proposed is lower — increment counter before committing.
            history.framesAtLowerLevel += 1
            if history.framesAtLowerLevel >= deescalationFrames {
                // Enough consecutive lower frames — commit deescalation.
                history.level = proposed
                history.framesAtLowerLevel = 0
            }
            // Otherwise keep the current (higher) committed level.
        }

        threatHistory[targetID] = history
        return history.level
    }
}
