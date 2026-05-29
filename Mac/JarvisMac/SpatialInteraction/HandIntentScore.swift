import Foundation
import CoreGraphics

// MARK: - SuppressionReason

/// Why a hand is being ignored by the gesture layer.
enum SuppressionReason: String, Equatable {
    case faceContact        = "Face contact"
    case lowConfidence      = "Low confidence"
    case incompleteLandmarks = "Incomplete landmarks"
    case shakingDetected    = "Shaking"
    case jerkDetected       = "Jerk"
    case microTremor        = "Micro tremor"
    case unstableSecondHand = "Unstable second hand"
    case restingPosition    = "Resting"
    case cooldown           = "Cooldown"
    case paused             = "Tracking paused"
    case objectHeld         = "Object held"
    case tooFast            = "Too fast"
    case disabled           = "Tracking disabled"
    case accidentalMotion   = "Accidental motion"
}

// MARK: - HandIntentScore

/// Multi-factor scoring model for a single hand observation frame.
///
/// The scoring pipeline:
///  Vision confidence → raw confidence
///  landmark completeness → how well are all joints detected?
///  stability → position scatter over recent frames
///  velocity → is the hand moving at an intentional speed?
///  acceleration → smooth vs jerky?
///  face proximity → is the hand near the face?
///  dominant hand → slight boost for the user's preferred hand
///  gesture history → recent success/cancel ratio
///
/// Outputs:
///  `eligibilityScore`       — 0–1: can this hand control anything right now?
///  `intentScore`            — 0–1: does this look like intentional input?
///  `activeGestureLikelihood` — 0–1: is a specific gesture currently forming?
///  `suppressionReason`      — non-nil means suppress completely
struct HandIntentScore {

    // ── Factor inputs (0–1 each) ───────────────────────────────────────
    var rawConfidence:          Float = 0
    var landmarkCompleteness:   Float = 0
    var stabilityScore:         Float = 0
    var velocityScore:          Float = 0   // 1 = deliberate, 0 = too fast
    var accelerationScore:      Float = 0   // 1 = smooth, 0 = jerky
    var faceDistanceScore:      Float = 0   // 1 = clear, 0 = touching face
    var dominantHandBonus:      Float = 0   // 0 or +0.05
    var gestureHistoryScore:    Float = 0.5 // recent success ratio

    // ── Computed outputs ───────────────────────────────────────────────
    var eligibilityScore:        Float = 0
    var intentScore:             Float = 0
    var activeGestureLikelihood: Float = 0

    // ── Suppression ────────────────────────────────────────────────────
    var suppressionReason: SuppressionReason? = nil
    var isSuppressed: Bool { suppressionReason != nil }

    // MARK: - Factory

    /// Compute a full score from one frame of data.
    ///
    /// - Parameters:
    ///   - pose: the hand pose from Vision
    ///   - recentPositions: last N screen-space positions (pts)
    ///   - recentVelocities: last N velocity magnitudes (pts/s)
    ///   - isFaceNear: true if wrist/palm overlaps the face exclusion zone
    ///   - isDominantHand: true for the user's preferred hand
    ///   - recentSuccessRate: fraction of recent gestures that completed (0–1)
    ///   - recentCancelRate: fraction of recent gestures that were cancelled (0–1)
    ///   - minConfidence: minimum raw confidence to be eligible at all
    ///   - isAccidentalMotion: true if AccidentalMotionDetector flagged this frame
    static func compute(
        pose:               HandPose,
        recentPositions:    [CGPoint],
        recentVelocities:   [CGFloat],
        isFaceNear:         Bool,
        isDominantHand:     Bool,
        recentSuccessRate:  Float,
        recentCancelRate:   Float,
        minConfidence:      Float,
        isAccidentalMotion: Bool
    ) -> HandIntentScore {

        var s = HandIntentScore()

        // ── Raw confidence ──────────────────────────────────────────────
        s.rawConfidence = pose.confidence

        // ── Landmark completeness ───────────────────────────────────────
        let joints: [CGPoint] = [
            pose.wrist, pose.thumbTip,
            pose.indexTip, pose.indexMCP,
            pose.middleTip, pose.middleMCP,
            pose.ringTip, pose.ringMCP,
            pose.littleTip, pose.littleMCP
        ]
        let detected = joints.filter { $0.x > 0.001 || $0.y > 0.001 }.count
        s.landmarkCompleteness = Float(detected) / Float(joints.count)

        // ── Face proximity ──────────────────────────────────────────────
        s.faceDistanceScore = isFaceNear ? 0.0 : 1.0

        // ── Hard gates — fail fast before expensive calculations ────────
        // Confidence gate: very permissive (0.20) since partial occlusion
        // (hand in front of face/body) significantly drops Vision confidence.
        if pose.confidence < minConfidence {
            s.suppressionReason = .lowConfidence
            return s
        }
        // Face proximity: no longer a hard gate — hands naturally appear
        // in front of the face/body for screen-level gestures. Apply a score
        // penalty in the eligibility calculation instead.
        //
        // if isFaceNear { s.suppressionReason = .faceContact; return s }
        //
        // Landmark completeness: lowered to 0.3 (3 of 10 joints visible).
        // Partial hands (fingers at edge of camera frame) are still useful.
        if s.landmarkCompleteness < 0.30 {
            s.suppressionReason = .incompleteLandmarks
            return s
        }
        if isAccidentalMotion {
            s.suppressionReason = .accidentalMotion
            return s
        }

        // ── Stability (position scatter) ────────────────────────────────
        if recentPositions.count >= 3 {
            let xs: [Double] = recentPositions.map { Double($0.x) }
            let ys: [Double] = recentPositions.map { Double($0.y) }
            let count: Double = Double(xs.count)
            let mx: Double = xs.reduce(0, +) / count
            let my: Double = ys.reduce(0, +) / count
            // Broken into explicit steps so the type-checker doesn't have to
            // solve one large polymorphic expression (was: compiler timeout).
            let squaredDistances: [Double] = zip(xs, ys).map { (x: Double, y: Double) -> Double in
                let dx: Double = x - mx
                let dy: Double = y - my
                return dx * dx + dy * dy
            }
            let sumSquared: Double = squaredDistances.reduce(0, +)
            let variance: Double = sumSquared / count
            let stdDev: Float = Float(sqrt(variance))
            s.stabilityScore = max(0, min(1, 1.0 - stdDev / 22.0))
        } else {
            s.stabilityScore = 0.5
        }

        // ── Velocity score ──────────────────────────────────────────────
        if let lastV = recentVelocities.last {
            let maxExpected: CGFloat = 380
            s.velocityScore = Float(max(0, min(1, 1.0 - lastV / maxExpected)))
        } else {
            s.velocityScore = 0.8
        }

        // ── Acceleration / jerkiness ────────────────────────────────────
        if recentVelocities.count >= 2 {
            let diffs = zip(recentVelocities, recentVelocities.dropFirst())
                .map { abs(Double($1 - $0)) }
            let maxDiff = diffs.max() ?? 0
            s.accelerationScore = Float(max(0, min(1, 1.0 - maxDiff / 180.0)))
        } else {
            s.accelerationScore = 0.8
        }

        // ── Dominant hand ───────────────────────────────────────────────
        s.dominantHandBonus = isDominantHand ? 0.05 : 0.0

        // ── Gesture history ─────────────────────────────────────────────
        s.gestureHistoryScore = max(0, recentSuccessRate - recentCancelRate * 0.4)

        // ── Eligibility score (weighted average) ────────────────────────
        // Confidence and completeness are the gate; stability and velocity refine.
        s.eligibilityScore = cap(
            s.rawConfidence        * 0.30 +
            s.landmarkCompleteness * 0.25 +
            s.stabilityScore       * 0.20 +
            s.velocityScore        * 0.12 +
            s.faceDistanceScore    * 0.08 +
            s.gestureHistoryScore  * 0.05 +
            s.dominantHandBonus
        )

        // ── Intent score ────────────────────────────────────────────────
        s.intentScore = cap(
            s.eligibilityScore     * 0.50 +
            s.accelerationScore    * 0.20 +
            s.gestureHistoryScore  * 0.15 +
            s.velocityScore        * 0.15
        )

        // ── Active gesture likelihood ───────────────────────────────────
        // Moving but controlled = deliberate intent. Pure stillness or chaos = low.
        // Broken into explicit steps to keep the type-checker fast.
        let normalizedVelocity: Double
        if let lastVel = recentVelocities.last {
            normalizedVelocity = min(1.0, Double(lastVel) / 200.0)
        } else {
            normalizedVelocity = 0.3
        }
        let movingFactor: Float = Float(1.0 - normalizedVelocity)
        let movingButControlled: Float = movingFactor * s.stabilityScore
        s.activeGestureLikelihood = cap(s.intentScore * 0.70 + movingButControlled * 0.30)

        return s
    }

    private static func cap(_ v: Float) -> Float { max(0, min(1, v)) }
}
