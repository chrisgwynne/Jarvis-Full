import Foundation
import CoreGraphics

// MARK: - SpatialInteractionConfig

/// Centralised tuning knobs for the spatial hand-tracking layer.
///
/// Changing any value takes effect on the next camera frame — no restart
/// needed. All thresholds are documented in terms of the physical
/// phenomenon they prevent, not just their units.
struct SpatialInteractionConfig {

    // ── Confidence ─────────────────────────────────────────────────────────

    /// Minimum Vision observation confidence to accept a hand at all.
    /// Lowered to 0.20 — partial occlusion (hand in front of face/body)
    /// drops Vision confidence significantly; a strict gate means the hand
    /// is never recognised in those positions.
    var handConfidenceThreshold: Float = 0.20

    /// Minimum confidence for the *secondary* hand before it can participate
    /// in any gesture. Higher than primary because a shaky secondary hand
    /// is the leading cause of accidental resize activation.
    var secondHandConfidenceThreshold: Float = 0.35

    /// Consecutive frames the secondary hand must be present above its
    /// confidence threshold before it becomes eligible for two-hand gestures.
    /// Lowered to 10 frames (~167 ms at 60 fps).
    var secondHandDwellFrames: Int = 10

    // ── Dominant hand lock ─────────────────────────────────────────────────

    /// Frames the dominant/primary hand must be absent before the system
    /// allows the other hand to take over as the active pointer hand.
    /// Lowered to 15 frames (~250 ms) — less sluggish hand-swap.
    var dominantHandLockoutFrames: Int = 15

    // ── Pinch ──────────────────────────────────────────────────────────────

    /// Consecutive frames thumb+index must stay within `pinchThreshold`
    /// before the pinch is *confirmed* (transitions from candidate → pinching).
    /// Lowered to 2 frames — quicker pinch response.
    var pinchDwellFrames: Int = 2

    /// Consecutive frames thumb+index must stay *above* (threshold + releaseGap)
    /// before a pinch release is confirmed.
    var pinchReleaseDwellFrames: Int = 2

    /// Below this normalised (0–1) distance between thumb tip and index tip
    /// the system enters the pinch candidate state.
    var pinchThreshold: Float = 0.045

    /// Hysteresis gap: release requires the distance to exceed
    /// `pinchThreshold + pinchReleaseGap`.  Larger gap = stickier pinch.
    var pinchReleaseGap: Float = 0.015

    // ── Resize gating ──────────────────────────────────────────────────────

    /// Consecutive frames both hands must be simultaneously stable (low velocity)
    /// before the system transitions from twoHandCandidate → resizing.
    /// ~416 ms at 60 fps.  Makes accidental resize nearly impossible because
    /// the user must hold *both* hands perfectly still before resize triggers.
    var resizeDwellFrames: Int = 25

    /// Minimum *change* in normalised inter-hand distance needed to actually
    /// fire a resize event (as a fraction of the baseline distance).
    /// 0.08 = 8% spread change. Ignores small natural hand-position variation.
    var resizeStartThreshold: CGFloat = 0.08

    /// Maximum smoothed cursor speed (pts/s) at which a hand is considered
    /// "stable" for the resize-entry dwell gate.
    var handStabilityMaxSpeedPts: CGFloat = 55

    // ── Face contact suppression ────────────────────────────────────────────

    /// Extra padding (normalised Vision 0–1 space) added around the detected
    /// face bounding box. Set to 0.0 — face-zone suppression is disabled because
    /// users naturally gesture in front of their face/body and the strict gate
    /// caused the hand to never be recognised.
    var facePaddingNorm: CGFloat = 0.0

    /// Frames a hand must stay *outside* the face exclusion zone before it
    /// regains interaction eligibility. Set to 1 — nearly instant re-entry
    /// so the cursor doesn't vanish when the hand briefly crosses the face zone.
    var faceExitDwellFrames: Int = 1

    // ── Smoothing ──────────────────────────────────────────────────────────

    /// Primary position EMA factor. Raised to 0.25 for snappier response —
    /// users need to see the cursor react quickly to know tracking is working.
    var smoothingAlpha: CGFloat = 0.25

    /// Velocity damping EMA factor.
    var velocityAlpha: CGFloat = 0.07

    /// Velocity correction term weight. Keep low to avoid jitter amplification.
    var velocityCorrectionWeight: CGFloat = 0.10

    // ── Sensitivity ────────────────────────────────────────────────────────

    /// Scale applied to the per-frame cursor delta in hover/pointer mode.
    /// Raised to 1.3 — camera-to-screen hand motion ratio is smaller than
    /// raw Vision coords suggest, so movement needs amplification.
    var pointerSensitivity: CGFloat = 1.3

    /// Scale applied to cursor delta while dragging an overlay.
    var dragSensitivity: CGFloat = 0.80

    /// Scale applied to the inter-hand distance change during resize.
    var resizeSensitivity: CGFloat = 0.80

    // ── Deadzone ───────────────────────────────────────────────────────────

    /// Raw input movement below this magnitude (pts/frame) is suppressed.
    /// Eliminates physiological hand tremor (typically 4–8 Hz) from the cursor.
    /// Set to 0 to disable.
    var deadzonePts: CGFloat = 4.0

    /// Maximum allowed cursor jump per frame (pts).  Jumps larger than this
    /// are clamped to this distance, preventing teleportation artefacts that
    /// occur when Vision loses and re-acquires a hand in a different position.
    var maxJumpPts: CGFloat = 120.0

    // ── Hand candidate dwell ────────────────────────────────────────────────

    /// Frames a newly-detected hand must be held before becoming eligible.
    /// Lowered to 2 frames — hand should activate almost immediately.
    var handCandidateDwellFrames: Int = 2

    /// Frames a suppressed hand must stay clear before regaining eligibility.
    /// Lowered to 6 frames — faster re-entry after suppression.
    var suppressedExitDwellFrames: Int = 6

    /// Frames of post-gesture cooldown after a pinch release.
    var gesturePostCooldownFrames: Int = 4

    // ── Intent / eligibility gating ────────────────────────────────────────

    /// Minimum `HandIntentScore.eligibilityScore` before the hand controls UI.
    /// Set to 0.0 — the confidence/completeness hard gates in HandIntentScore
    /// already reject truly bad detections; adding a score floor here suppresses
    /// the cursor for partially-detected hands that are still usable.
    var eligibilityThreshold: Float = 0.0

    /// Minimum `HandIntentScore.intentScore` before pinch/drag is attempted.
    var intentThreshold: Float = 0.12

    // ── Y-axis remapping ───────────────────────────────────────────────────

    /// Vision Y (0=bottom, 1=top) at which the cursor sits at the BOTTOM of
    /// the screen. Hands resting near desk level appear here in the camera frame.
    /// Tune upward if the cursor starts too high.
    var cursorYRangeMin: CGFloat = 0.05

    /// Vision Y at which the cursor sits at the TOP of the screen. Hands raised
    /// toward the camera (top of monitor) appear here. Tune downward if the top
    /// of the screen is unreachable. Typical range 0.50–0.70.
    var cursorYRangeMax: CGFloat = 0.62

    // ── Calibration sampling ────────────────────────────────────────────────

    /// Every Nth frame, the coordinator records a speed sample to the
    /// calibration store.  Lower = finer data, higher = less overhead.
    var calibrationSampleInterval: Int = 6

    // ── Singleton ──────────────────────────────────────────────────────────

    /// Live-mutable shared instance. Modify at runtime; no restart needed.
    static var shared = SpatialInteractionConfig()
}
