import Foundation
import CoreGraphics

// MARK: - Cursor Sensitivity Mode

/// The current interaction context, used to select the appropriate
/// sensitivity and smoothing preset.
enum CursorSensitivityMode {
    /// Normal hover / pointer mode — standard sensitivity.
    case pointer
    /// Dragging an overlay panel — slower and more controlled.
    case drag
    /// Two-hand resize — slowest, most deliberate.
    case resize
}

// MARK: - SpatialCursorEngine

/// Converts raw Vision-framework hand joint positions to smooth, stable
/// screen-space cursor positions.
///
/// Improvements over the original implementation:
/// - **Deadzone**: movements below `config.deadzonePts` are suppressed,
///   eliminating physiological tremor from the cursor.
/// - **Jump clamp**: per-frame position changes above `config.maxJumpPts`
///   are clamped, preventing cursor teleportation when Vision briefly
///   loses and re-acquires the hand.
/// - **Sensitivity multiplier**: applied to the per-frame delta, making
///   the cursor move at `sensitivity × rawSpeed` rather than raw speed.
///   Separate values for pointer, drag, and resize modes.
/// - **Lower EMA alpha**: smoother default (0.10 vs 0.18) gives a more
///   premium, weighted feel without sacrificing responsiveness.
///
/// Pipeline:
///   raw Vision point (normalised, bottom-left Y-up)
///   → mirror X, flip Y
///   → scale to view size
///   → jump clamp
///   → deadzone filter
///   → sensitivity scale
///   → EMA position smoothing
///   → velocity damping
///   → output: CGPoint in view coordinates
final class SpatialCursorEngine {

    // MARK: - Configuration

    /// Active sensitivity mode. Switch this before calling `update()`.
    var sensitivityMode: CursorSensitivityMode = .pointer

    /// The view size cursor positions are expressed in.
    var viewSize: CGSize = .zero

    /// Mirror input X axis (required for front-facing camera).
    var mirrorX: Bool = true

    /// Active spatial calibration.  When set, the affine transform replaces
    /// the hardcoded linear remap entirely.  Set by the coordinator after
    /// loading from disk or after a calibration session completes.
    var calibration: AffineCalibration? = nil

    // MARK: - Private state

    private var smoothedPosition: CGPoint = .zero
    private var smoothedVelocity: CGPoint = .zero
    private var lastPosition:     CGPoint = .zero
    private var lastRawPosition:  CGPoint = .zero   // last *accepted* raw position
    private var isInitialized = false

    // MARK: - Update

    /// Feed a Vision normalised point (origin bottom-left). Returns the
    /// smoothed cursor position in view coordinates, or the last known
    /// position if input is nil or below deadzone.
    @discardableResult
    func update(normalizedPoint: CGPoint?) -> CGPoint? {
        guard let raw = normalizedPoint,
              viewSize.width > 0, viewSize.height > 0 else {
            return isInitialized ? smoothedPosition : nil
        }

        let cfg = SpatialInteractionConfig.shared

        // ── Coordinate transform ────────────────────────────────────────
        // Two paths:
        //
        // A) Calibrated — affine transform fitted from user's confirmed
        //    capture pairs maps Vision-space directly to view-space.
        //    All non-linearity (camera angle, position, mirror) is baked in.
        //
        // B) Default — hardcoded linear remap. Used when no calibration
        //    has been performed or after a reset.
        // ── Calibrated path — absolute EMA, no delta accumulation ──────
        // The affine transform already encodes all camera geometry.
        // We just smooth toward the target position directly; no deadzone,
        // jump clamp, or sensitivity scale needed (those would fight the
        // calibration and cause the cursor to drift away from the finger).
        if let calib = calibration {
            let mapped = calib.apply(raw)
            let target = CGPoint(
                x: max(0, min(viewSize.width,  mapped.x)),
                y: max(0, min(viewSize.height, mapped.y))
            )
            if !isInitialized {
                smoothedPosition = target
                lastPosition     = target
                lastRawPosition  = target
                isInitialized    = true
                return smoothedPosition
            }
            smoothedPosition = lerp(smoothedPosition, target, cfg.smoothingAlpha)
            lastRawPosition  = target
            lastPosition     = smoothedPosition
            return smoothedPosition
        }

        // ── Uncalibrated path — hardcoded linear remap ──────────────────
        // Vision: (0,0) = bottom-left, Y increases upward.
        // SwiftUI/NSView: (0,0) = top-left, Y increases downward.
        let yRange = cfg.cursorYRangeMax - cfg.cursorYRangeMin
        let remappedY: CGFloat
        if yRange > 0.01 {
            remappedY = max(0, min(1, (raw.y - cfg.cursorYRangeMin) / yRange))
        } else {
            remappedY = max(0, min(1, raw.y))
        }
        let x = (mirrorX ? (1.0 - raw.x) : raw.x) * viewSize.width
        let y = (1.0 - remappedY) * viewSize.height
        let screenPos = CGPoint(x: x, y: y)

        // ── Bootstrap ───────────────────────────────────────────────────
        if !isInitialized {
            smoothedPosition = screenPos
            lastPosition     = screenPos
            lastRawPosition  = screenPos
            isInitialized    = true
            return smoothedPosition
        }

        // ── Per-frame delta ─────────────────────────────────────────────
        var delta = CGPoint(x: screenPos.x - lastRawPosition.x,
                            y: screenPos.y - lastRawPosition.y)
        let deltaMag = hypot(delta.x, delta.y)

        // ── Jump clamp (tracking noise / hand swap artefacts) ───────────
        if deltaMag > cfg.maxJumpPts {
            let scale = cfg.maxJumpPts / deltaMag
            delta = CGPoint(x: delta.x * scale, y: delta.y * scale)
        }

        // ── Deadzone (tremor suppression) ───────────────────────────────
        let effectiveDeltaMag = hypot(delta.x, delta.y)
        if effectiveDeltaMag < cfg.deadzonePts {
            lastRawPosition = lerp(lastRawPosition, screenPos, 0.15)
            return smoothedPosition
        }

        lastRawPosition = screenPos

        // ── Sensitivity scaling ─────────────────────────────────────────
        let sensitivity = currentSensitivity(cfg: cfg)
        let adjustedPos = CGPoint(
            x: smoothedPosition.x + delta.x * sensitivity,
            y: smoothedPosition.y + delta.y * sensitivity
        )

        // ── EMA position smoothing ──────────────────────────────────────
        smoothedPosition = lerp(smoothedPosition, adjustedPos, cfg.smoothingAlpha)

        // ── Velocity damping ────────────────────────────────────────────
        let rawVelocity = CGPoint(
            x: smoothedPosition.x - lastPosition.x,
            y: smoothedPosition.y - lastPosition.y
        )
        smoothedVelocity = lerp(smoothedVelocity, rawVelocity, cfg.velocityAlpha)
        smoothedPosition = CGPoint(
            x: smoothedPosition.x + smoothedVelocity.x * cfg.velocityCorrectionWeight,
            y: smoothedPosition.y + smoothedVelocity.y * cfg.velocityCorrectionWeight
        )

        lastPosition = smoothedPosition
        return smoothedPosition
    }

    func reset() {
        isInitialized    = false
        smoothedVelocity = .zero
        smoothedPosition = .zero
        lastRawPosition  = .zero
        lastPosition     = .zero
    }

    // MARK: - Helpers

    private func currentSensitivity(cfg: SpatialInteractionConfig) -> CGFloat {
        switch sensitivityMode {
        case .pointer: return cfg.pointerSensitivity
        case .drag:    return cfg.dragSensitivity
        case .resize:  return cfg.resizeSensitivity
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - SpatialCursorState

struct SpatialCursorState {
    var position:        CGPoint = .zero
    var isPinching:      Bool    = false
    var isVisible:       Bool    = false
    var isSuppressed:    Bool    = false    // true when score-based suppression active
    var eligibilityScore: Float  = 0        // 0–1 from HandIntentScore
    var intentScore:     Float   = 0        // 0–1 from HandIntentScore

    /// Scale for the cursor glow ring — expands slightly when near a hover target.
    var magneticScale: CGFloat = 1.0
}
