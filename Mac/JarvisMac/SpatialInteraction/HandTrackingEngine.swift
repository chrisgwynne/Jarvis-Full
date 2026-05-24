import Foundation
import Vision
import CoreVideo
import CoreGraphics

// MARK: - HandTrackingEngine

/// Runs `VNDetectHumanHandPoseRequest` and `VNDetectFaceRectanglesRequest`
/// on every camera frame on a background queue.
///
/// Improvements over the original:
/// - **Dominant hand lock**: tracks which Vision observation corresponds to
///   the user's dominant (primary) hand using wrist-position continuity across
///   frames.  When two observations are returned, the one whose wrist is
///   closest to the previous frame's dominant wrist is assigned as primary.
///   This prevents rapid left↔right swapping when both hands are visible.
/// - **Second hand stability counter**: counts consecutive frames the secondary
///   hand has been present above its confidence threshold.  The coordinator
///   uses this to gate two-hand gestures (resize) behind a dwell requirement.
/// - **Face detection**: `VNDetectFaceRectanglesRequest` runs on the same
///   `VNImageRequestHandler` as hand detection.  The padded face bounding box
///   is published so the coordinator can suppress hands touching the face.
@MainActor
final class HandTrackingEngine: ObservableObject {

    // MARK: - Published

    @Published private(set) var handPose:          HandPose?
    @Published private(set) var secondaryHandPose: HandPose?
    @Published private(set) var isHandPresent:     Bool = false

    /// Face bounding box in normalised Vision coordinates (origin bottom-left).
    /// Nil when no face is detected.
    @Published private(set) var faceRectNorm:      CGRect? = nil

    /// Consecutive frames the secondary hand has been detected above the
    /// secondary-confidence threshold.  Used by coordinator for dwell gate.
    @Published private(set) var secondHandStableFrames: Int = 0

    // MARK: - Private

    private let inferenceQueue = DispatchQueue(label: "com.jarvis.hand.tracking",
                                               qos: .userInteractive)
    private var isProcessing = false

    // Hand pose request — maximumHandCount = 2 for two-hand gestures.
    private let poseRequest: VNDetectHumanHandPoseRequest = {
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2
        return req
    }()

    // Face detection request — runs alongside hand pose for face-contact rejection.
    private let faceRequest = VNDetectFaceRectanglesRequest()

    // ── Dominant hand lock state ────────────────────────────────────────────

    /// Wrist position (Vision normalised) of the dominant hand in the previous frame.
    private var dominantWristPos:    CGPoint?

    /// Frames since the dominant hand was last seen.  When this exceeds the
    /// lockout threshold, we allow any hand to become dominant.
    private var dominantAbsentFrames: Int = 0

    /// Running count for secondary hand stability (written on inference queue,
    /// read on main actor via published wrapper).
    private var secondStableCount: Int = 0

    // MARK: - Process frame

    /// Feed every camera frame here.  Frames are dropped if the previous
    /// inference hasn't finished — this keeps throughput ≤60 fps without queuing.
    func process(pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        isProcessing = true

        inferenceQueue.async { [weak self] in
            guard let self else { return }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .up,
                                                options: [:])
            var primary:   HandPose? = nil
            var secondary: HandPose? = nil
            var detectedFaceRect: CGRect? = nil

            do {
                // Both requests share a single handler — one decoder pass.
                try handler.perform([self.poseRequest, self.faceRequest])

                // ── Face rect ──────────────────────────────────────────────
                detectedFaceRect = self.faceRequest.results?.first?.boundingBox

                // ── Hand observations ──────────────────────────────────────
                let cfg = SpatialInteractionConfig.shared
                let results = self.poseRequest.results ?? []

                var obs0: HandPose? = nil
                var obs1: HandPose? = nil
                if let r0 = results.first {
                    obs0 = HandPose(observation: r0,
                                   confidenceThreshold: cfg.handConfidenceThreshold)
                }
                if results.count > 1, let r1 = results.dropFirst().first {
                    obs1 = HandPose(observation: r1,
                                   confidenceThreshold: cfg.handConfidenceThreshold)
                }

                // ── Dominant hand assignment ────────────────────────────────
                // If we have two hands, use wrist-position continuity to decide
                // which is the dominant (primary) hand.
                if let p0 = obs0, let p1 = obs1 {
                    if let dominantWrist = self.dominantWristPos {
                        let d0 = hypot(p0.wrist.x - dominantWrist.x,
                                       p0.wrist.y - dominantWrist.y)
                        let d1 = hypot(p1.wrist.x - dominantWrist.x,
                                       p1.wrist.y - dominantWrist.y)
                        if d1 < d0 {
                            // r1 better matches the dominant wrist — swap
                            primary   = p1
                            secondary = p0
                        } else {
                            primary   = p0
                            secondary = p1
                        }
                    } else {
                        // No prior dominant — pick r0 as primary (Vision's first result)
                        primary   = p0
                        secondary = p1
                    }
                } else if let p0 = obs0 {
                    primary   = p0
                    secondary = nil
                } else if let p1 = obs1 {
                    primary   = p1
                    secondary = nil
                }

                // ── Dominant hand lock update ──────────────────────────────
                if let prim = primary {
                    self.dominantWristPos    = prim.wrist
                    self.dominantAbsentFrames = 0
                } else {
                    self.dominantAbsentFrames += 1
                    if self.dominantAbsentFrames > cfg.dominantHandLockoutFrames {
                        // Lock expired — next hand becomes dominant from scratch
                        self.dominantWristPos    = nil
                        self.dominantAbsentFrames = 0
                    }
                }

                // ── Second hand stability counter ──────────────────────────
                if let sec = secondary,
                   sec.confidence >= cfg.secondHandConfidenceThreshold {
                    self.secondStableCount = min(self.secondStableCount + 1, 200)
                } else {
                    // Decay at 2× the accumulation rate so brief disappearances
                    // don't immediately reset a well-established stable count.
                    self.secondStableCount = max(self.secondStableCount - 2, 0)
                }

            } catch {
                // Vision inference failures are non-fatal.
            }

            let stableCount = self.secondStableCount

            Task { @MainActor in
                self.handPose              = primary
                self.secondaryHandPose     = secondary
                self.isHandPresent         = primary != nil
                self.faceRectNorm          = detectedFaceRect
                self.secondHandStableFrames = stableCount
                self.isProcessing          = false
            }
        }
    }

    func reset() {
        handPose               = nil
        secondaryHandPose      = nil
        isHandPresent          = false
        faceRectNorm           = nil
        secondHandStableFrames = 0
        isProcessing           = false
        dominantWristPos       = nil
        dominantAbsentFrames   = 0
        secondStableCount      = 0
    }
}
