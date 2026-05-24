import Foundation
import CoreGraphics
import CoreImage

// MARK: - MotionZoneEngine

/// Actor that manages a set of named, configurable motion zones and fires a callback
/// when a detection (or raw motion) triggers an armed zone.
///
/// Cooldown: once a zone fires, it cannot fire again for `cooldownInterval` seconds.
/// Overlap criterion: the intersection of a detection bounding rect with the zone rect
/// must be at least 30 % of the zone's own area.
actor MotionZoneEngine {

    // MARK: State

    private var zones: [UUID: MotionZoneDescriptor] = [:]
    /// Maps zoneID → the host-time deadline (CACurrentMediaTime equivalent) after which
    /// the zone is allowed to fire again. We use TimeInterval from Date.timeIntervalSinceReferenceDate.
    private var cooldowns: [UUID: TimeInterval] = [:]
    private let cooldownInterval: TimeInterval = 5.0
    private var onZoneTriggered: ((MotionZoneDescriptor, Float) -> Void)?

    // MARK: Default Zones

    /// A convenient starter set of zones wired to the primary camera feed.
    static let defaultZones: [MotionZoneDescriptor] = [
        MotionZoneDescriptor(
            id: UUID(),
            name: "Full Frame",
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            sensitivityThreshold: 0.15,
            isArmed: true,
            cameraFeedID: CameraFeedManager.primaryFeedID
        ),
    ]

    // MARK: Configuration

    /// Replace the entire zone map. Existing cooldowns are preserved if the zone ID is kept.
    func setZones(_ newZones: [MotionZoneDescriptor]) {
        zones = Dictionary(uniqueKeysWithValues: newZones.map { ($0.id, $0) })
        // Prune cooldowns for zones that no longer exist.
        let validIDs = Set(zones.keys)
        cooldowns = cooldowns.filter { validIDs.contains($0.key) }
    }

    /// Register a single additional zone without replacing others.
    func addZone(_ zone: MotionZoneDescriptor) {
        zones[zone.id] = zone
    }

    /// Remove a zone by ID.
    func removeZone(id: UUID) {
        zones.removeValue(forKey: id)
        cooldowns.removeValue(forKey: id)
    }

    /// Set the callback invoked when a zone triggers.
    /// Receives the zone descriptor and the intensity/confidence value that triggered it.
    func setCallback(_ cb: @escaping (MotionZoneDescriptor, Float) -> Void) {
        onZoneTriggered = cb
    }

    // MARK: Evaluation

    /// Evaluate a batch of raw detections from one analysis frame against all armed zones.
    ///
    /// - Parameters:
    ///   - detections: Raw bounding-box detections from the pipeline (normalized coords).
    ///   - motionIntensity: 0–1 scalar motion magnitude for the whole frame.
    ///   - timestamp: Wall-clock time (`Date().timeIntervalSinceReferenceDate`).
    func evaluate(
        detections: [RawDetection],
        motionIntensity: Float,
        timestamp: TimeInterval
    ) {
        for (zoneID, zone) in zones {
            guard zone.isArmed else { continue }

            // Cooldown check
            if let deadline = cooldowns[zoneID], timestamp < deadline {
                continue
            }

            // Criterion 1: any detection overlaps the zone.
            let detectionOverlap = detections.contains { overlaps(detection: $0, zone: zone) }

            // Criterion 2: overall motion intensity exceeds the zone's threshold.
            // (This fires even when there are no classified detections, e.g., shadows.)
            let motionTrigger = motionIntensity > zone.sensitivityThreshold

            if detectionOverlap || motionTrigger {
                // Commit cooldown before invoking callback so re-entrant calls are safe.
                cooldowns[zoneID] = timestamp + cooldownInterval

                // Determine the intensity value to report: use highest overlapping detection
                // confidence if available, otherwise fall back to raw motion intensity.
                let triggerIntensity: Float
                if detectionOverlap {
                    triggerIntensity = detections
                        .filter { overlaps(detection: $0, zone: zone) }
                        .map { $0.confidence }
                        .max() ?? motionIntensity
                } else {
                    triggerIntensity = motionIntensity
                }

                let callback = onZoneTriggered
                // Dispatch to the calling context (caller is @MainActor via VisionDetectionPipeline).
                Task { @MainActor in
                    callback?(zone, triggerIntensity)
                }
            }
        }
    }

    // MARK: Private helpers

    /// Returns `true` if the detection's bounding rect overlaps the zone's rect by more
    /// than 30 % of the zone's area.
    private func overlaps(detection: RawDetection, zone: MotionZoneDescriptor) -> Bool {
        let zoneRect = zone.normalizedRect
        let area = intersectionArea(detection.bounds, zoneRect)
        let zoneArea = zoneRect.width * zoneRect.height
        guard zoneArea > 0 else { return false }
        return area / zoneArea > 0.3
    }

    /// Returns the area of the rectangle formed by the intersection of `a` and `b`.
    /// Returns 0 if the rects do not intersect.
    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull && !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
