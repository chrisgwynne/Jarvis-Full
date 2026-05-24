import Foundation
import CoreGraphics

// MARK: - ObjectTracker

/// Temporal target tracker that maintains persistent IDs across frames.
/// Matches new detections to existing targets using IoU overlap, smooths bounding boxes,
/// promotes targets to ghost state when detections are lost, and purges stale ghosts.
@MainActor
final class ObjectTracker {

    // MARK: Configuration

    /// How long a ghost target is retained after its last real detection.
    private let ghostDuration: TimeInterval = 2.0
    /// Minimum IoU score to consider two rects as the same target.
    private let reacquisitionDistance: CGFloat = 0.15
    /// Max consecutive frames without detection before promoting to ghost.
    private let maxMissedFrames: Int = 8
    /// Exponential smoothing alpha for bounding-box position (0 = no update, 1 = instant snap).
    private let smoothingAlpha: CGFloat = 0.35
    /// Smoothing alpha for velocity estimation.
    private let velocityAlpha: CGFloat = 0.2

    // MARK: State

    private var targets: [UUID: TrackedTarget] = [:]
    private var sequenceCounter: Int = 0
    /// Timestamp of the last processed frame, used for velocity computation.
    private var lastFrameTimestamp: TimeInterval = 0
    /// Previous centers per target ID, for velocity estimation.
    private var previousCenters: [UUID: CGPoint] = [:]
    /// Smoothed velocities per target ID.
    private var smoothedVelocities: [UUID: CGVector] = [:]

    /// All currently active targets sorted by firstSeen (ascending), ghosts at the end.
    private(set) var activeTargets: [TrackedTarget] = []

    // MARK: Public API

    /// Incorporate a new DetectionFrame into the tracker state.
    func update(with frame: DetectionFrame) {
        let now = Date()
        let deltaTime = frame.timestamp - lastFrameTimestamp
        let validDelta = lastFrameTimestamp > 0 && deltaTime > 0 && deltaTime < 2.0

        // Snapshot living (non-ghost) targets for matching
        let livingTargets = targets.values.filter { !$0.isGhost && $0.cameraFeedID == frame.cameraFeedID }

        // Track which target IDs were matched this frame
        var matchedTargetIDs = Set<UUID>()
        // Track which detections were consumed by existing targets
        var consumedDetectionIDs = Set<UUID>()

        // -- Pass 1: match each detection to an existing target --
        var updatedTargets: [UUID: TrackedTarget] = targets  // start with all existing

        for detection in frame.rawDetections {
            guard let matched = match(detection: detection, to: Array(livingTargets)) else {
                continue
            }
            matchedTargetIDs.insert(matched.id)
            consumedDetectionIDs.insert(detection.id)

            var t = updatedTargets[matched.id] ?? matched
            let newBounds = smoothBounds(t.bounds, toward: detection.bounds, alpha: smoothingAlpha)

            // Velocity
            let currentCenter = CGPoint(x: newBounds.midX, y: newBounds.midY)
            if validDelta, let prevCenter = previousCenters[t.id] {
                let rawVelX = (currentCenter.x - prevCenter.x) / CGFloat(deltaTime)
                let rawVelY = (currentCenter.y - prevCenter.y) / CGFloat(deltaTime)
                let prevVel = smoothedVelocities[t.id] ?? CGVector.zero
                let smoothedVel = CGVector(
                    dx: velocityAlpha * rawVelX + (1 - velocityAlpha) * prevVel.dx,
                    dy: velocityAlpha * rawVelY + (1 - velocityAlpha) * prevVel.dy
                )
                smoothedVelocities[t.id] = smoothedVel
                t.velocity = smoothedVel
            }
            previousCenters[t.id] = currentCenter

            t.bounds = newBounds
            t.confidence = 0.7 * Float(detection.confidence) + 0.3 * t.confidence
            t.lastSeen = now
            t.isGhost = false
            t.missedFrames = 0
            // Promote threat level if detection class suggests it, never demote automatically
            if detection.cls.defaultThreat > t.threatLevel {
                t.threatLevel = detection.cls.defaultThreat
            }
            updatedTargets[t.id] = t
        }

        // -- Pass 2: create new targets for unmatched detections --
        for detection in frame.rawDetections where !consumedDetectionIDs.contains(detection.id) {
            let newTarget = createTarget(from: detection)
            previousCenters[newTarget.id] = CGPoint(x: newTarget.bounds.midX, y: newTarget.bounds.midY)
            updatedTargets[newTarget.id] = newTarget
        }

        // -- Pass 3: increment missedFrames for non-matched living targets on this camera --
        for targetID in livingTargets.map(\.id) where !matchedTargetIDs.contains(targetID) {
            guard var t = updatedTargets[targetID] else { continue }
            t.missedFrames += 1
            if t.missedFrames > maxMissedFrames {
                t.isGhost = true
            }
            updatedTargets[targetID] = t
        }

        targets = updatedTargets
        lastFrameTimestamp = frame.timestamp

        // Rebuild the sorted public array
        rebuildActiveTargets()
    }

    /// Remove targets that have been in ghost state longer than `ghostDuration`.
    func purgeStale() {
        let now = Date()
        let staleIDs = targets.compactMap { (id, target) -> UUID? in
            guard target.isGhost else { return nil }
            return now.timeIntervalSince(target.lastSeen) > ghostDuration ? id : nil
        }
        for id in staleIDs {
            targets.removeValue(forKey: id)
            previousCenters.removeValue(forKey: id)
            smoothedVelocities.removeValue(forKey: id)
        }
        if !staleIDs.isEmpty {
            rebuildActiveTargets()
        }
    }

    /// All targets (including ghosts) for a specific camera feed.
    func allTargets(for cameraID: UUID) -> [TrackedTarget] {
        targets.values.filter { $0.cameraFeedID == cameraID }
    }

    /// Clear all tracking state.
    func reset() {
        targets.removeAll()
        previousCenters.removeAll()
        smoothedVelocities.removeAll()
        sequenceCounter = 0
        lastFrameTimestamp = 0
        activeTargets = []
    }

    // MARK: Private helpers

    /// Find the best-matching existing target for a detection using IoU.
    /// Returns nil if no target exceeds the minimum IoU threshold with a compatible class.
    private func match(detection: RawDetection, to targets: [TrackedTarget]) -> TrackedTarget? {
        var bestTarget: TrackedTarget?
        var bestScore: CGFloat = 0.3  // minimum IoU threshold

        for target in targets {
            guard detection.cls.isCompatible(with: target.cls) else { continue }
            let score = iou(detection.bounds, target.bounds)
            if score > bestScore {
                bestScore = score
                bestTarget = target
            }
        }
        return bestTarget
    }

    /// Intersection-over-Union of two normalized rects.
    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull && !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    /// Create a brand-new TrackedTarget from a raw detection.
    private func createTarget(from detection: RawDetection) -> TrackedTarget {
        sequenceCounter += 1
        let label = TrackedTarget.makeLabel(cls: detection.cls, sequence: sequenceCounter)
        return TrackedTarget(
            id: UUID(),
            cls: detection.cls,
            bounds: detection.bounds,
            displayBounds: detection.bounds,
            confidence: detection.confidence,
            velocity: .zero,
            threatLevel: detection.cls.defaultThreat,
            firstSeen: Date(),
            lastSeen: Date(),
            isGhost: false,
            cameraFeedID: detection.cameraFeedID,
            trackLabel: label,
            missedFrames: 0
        )
    }

    /// Exponential smoothing of a bounding rect.
    /// `alpha` controls how quickly the smoothed rect moves toward the new value.
    private func smoothBounds(_ current: CGRect, toward new: CGRect, alpha: CGFloat = 0.35) -> CGRect {
        let oneMinusAlpha = 1.0 - alpha
        return CGRect(
            x: alpha * new.origin.x    + oneMinusAlpha * current.origin.x,
            y: alpha * new.origin.y    + oneMinusAlpha * current.origin.y,
            width: alpha * new.width   + oneMinusAlpha * current.width,
            height: alpha * new.height + oneMinusAlpha * current.height
        )
    }

    /// Rebuild `activeTargets` sorted by firstSeen, ghosts sorted to the end.
    private func rebuildActiveTargets() {
        activeTargets = targets.values.sorted { a, b in
            if a.isGhost != b.isGhost { return !a.isGhost }
            return a.firstSeen < b.firstSeen
        }
    }
}

// MARK: - CGVector helpers

extension CGVector {
    static let zero = CGVector(dx: 0, dy: 0)

    var magnitude: CGFloat {
        sqrt(dx * dx + dy * dy)
    }
}
