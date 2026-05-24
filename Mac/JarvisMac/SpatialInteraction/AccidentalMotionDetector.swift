import Foundation
import CoreGraphics

// MARK: - AccidentalMotionDetector

/// Rolling-window detector for non-intentional hand movement patterns.
///
/// Updated every Vision frame. Each call to `update()` returns a `Result`
/// describing which (if any) noise pattern was detected.
///
/// Detected patterns:
/// - **Shake** — rapid direction reversals (back-and-forth wrist flick)
/// - **Jerk** — single-frame velocity spike much larger than neighbours
/// - **Micro tremor** — high-frequency, very small amplitude oscillation
/// - **Bounce** — position oscillating around a fixed zone (resting hand)
final class AccidentalMotionDetector {

    // MARK: - Result

    struct Result {
        var isShaking:       Bool  = false
        var isJerking:       Bool  = false
        var hasMicroTremor:  Bool  = false
        var isBouncing:      Bool  = false
        /// 0–1: confidence that the current motion is accidental (not intentional).
        var accidentalConfidence: Float = 0

        /// True when any strong suppression pattern is active.
        var isSuppressible: Bool { isShaking || isJerking || hasMicroTremor }

        var reason: SuppressionReason? {
            if isJerking    { return .jerkDetected }
            if isShaking    { return .shakingDetected }
            if hasMicroTremor { return .microTremor }
            return nil
        }
    }

    // MARK: - Tuning

    /// Direction reversals in `shakeWindowFrames` to classify as shake.
    /// Raised to 6 — normal curved or arc gestures produce ~3 reversals; only
    /// deliberate wrist-flick shaking produces 6+ in 8 frames.
    var shakeReversalThreshold: Int = 6
    /// Rolling window (frames) inspected for shake / tremor.
    var shakeWindowFrames: Int = 8
    /// Velocity magnitude (pts/s) that, if spiked above surrounding frames × 3,
    /// classifies as a jerk.  Raised to 500 — typical hand gestures reach
    /// 200–800 pts/s; we only want to catch tracking artefacts (frame drops,
    /// hand swap) which produce >500 pts/s spikes.
    var jerkThresholdPts: CGFloat = 500
    /// Position amplitude (pts) below which high-frequency reversal = micro tremor.
    var microTremorMaxAmplitudePts: CGFloat = 5
    /// Minimum direction reversals in 8 frames to flag as micro tremor.
    /// Raised to 7 — physiological tremor is 4–12 Hz; at 60 fps, 7 reversals
    /// is a tighter gate that avoids misclassifying slow hand movement.
    var microTremorMinReversals: Int = 7
    /// Radius (pts) within which repeated return = bouncing.
    var bounceZoneRadius: CGFloat = 14

    // MARK: - Private rolling buffers

    private var positions:  [CGPoint] = []
    private var velocities: [CGFloat] = []
    private var directions: [Double]  = []   // angle in radians
    private let capacity = 20

    // MARK: - Update

    /// Feed one screen-space cursor position and its velocity magnitude.
    @discardableResult
    func update(position: CGPoint, velocityMagnitude: CGFloat) -> Result {
        positions.append(position)
        velocities.append(velocityMagnitude)
        if positions.count > capacity  { positions.removeFirst() }
        if velocities.count > capacity { velocities.removeFirst() }

        if positions.count >= 2 {
            let prev = positions[positions.count - 2]
            let curr = positions[positions.count - 1]
            let angle = atan2(Double(curr.y - prev.y), Double(curr.x - prev.x))
            directions.append(angle)
            if directions.count > capacity { directions.removeFirst() }
        }

        return analyse()
    }

    func reset() {
        positions.removeAll()
        velocities.removeAll()
        directions.removeAll()
    }

    // MARK: - Analysis

    private func analyse() -> Result {
        var r = Result()
        guard positions.count >= 4 else { return r }

        // ── Jerk: single-frame spike ────────────────────────────────────
        if velocities.count >= 4 {
            let window = Array(velocities.suffix(6))
            if let peak = window.max(),
               let low  = window.min(),
               peak > jerkThresholdPts,
               peak > low * 3.5 {
                r.isJerking = true
            }
        }

        // ── Shake: direction reversals in short window ──────────────────
        let dirWindow = Array(directions.suffix(shakeWindowFrames))
        if dirWindow.count >= shakeWindowFrames {
            var reversals = 0
            for i in 1..<dirWindow.count {
                let diff = wrappedDiff(dirWindow[i], dirWindow[i - 1])
                if abs(diff) > Double.pi * 0.55 { reversals += 1 }
            }
            r.isShaking = reversals >= shakeReversalThreshold
        }

        // ── Micro tremor: high-freq, tiny amplitude ─────────────────────
        let recentPos = Array(positions.suffix(8))
        if recentPos.count == 8 {
            let xs = recentPos.map { $0.x }
            let ys = recentPos.map { $0.y }
            let amplitude = max(
                (xs.max() ?? 0) - (xs.min() ?? 0),
                (ys.max() ?? 0) - (ys.min() ?? 0)
            )
            let recentDir = Array(directions.suffix(8))
            var microRev = 0
            for i in 1..<recentDir.count {
                if abs(wrappedDiff(recentDir[i], recentDir[i - 1])) > Double.pi * 0.45 {
                    microRev += 1
                }
            }
            r.hasMicroTremor = amplitude < microTremorMaxAmplitudePts &&
                               microRev >= microTremorMinReversals
        }

        // ── Bounce: oscillates within a fixed zone ──────────────────────
        if positions.count >= 8 {
            let recentP = Array(positions.suffix(8))
            let avgX = recentP.map { Double($0.x) }.reduce(0, +) / 8
            let avgY = recentP.map { Double($0.y) }.reduce(0, +) / 8
            let centre = CGPoint(x: avgX, y: avgY)
            let confined = recentP.allSatisfy {
                hypot($0.x - centre.x, $0.y - centre.y) < bounceZoneRadius
            }
            r.isBouncing = confined && r.isShaking
        }

        // ── Confidence ──────────────────────────────────────────────────
        var conf: Float = 0
        if r.isJerking    { conf += 0.50 }
        if r.isShaking    { conf += 0.40 }
        if r.hasMicroTremor { conf += 0.30 }
        if r.isBouncing   { conf += 0.20 }
        r.accidentalConfidence = min(1.0, conf)

        return r
    }

    // Signed angular difference wrapped to -π … π.
    private func wrappedDiff(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d >  Double.pi { d -= 2 * Double.pi }
        while d < -Double.pi { d += 2 * Double.pi }
        return d
    }
}
