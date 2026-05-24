import Foundation
import Vision
import CoreGraphics

// MARK: - Hand Pose Data

/// Flattened hand pose for easy consumption by classifiers and UI.
struct HandPose {
    let wrist:      CGPoint
    let thumbTip:   CGPoint
    let indexTip:   CGPoint
    let indexMCP:   CGPoint
    let middleTip:  CGPoint
    let middleMCP:  CGPoint
    let ringTip:    CGPoint
    let ringMCP:    CGPoint
    let littleTip:  CGPoint
    let littleMCP:  CGPoint
    let confidence: Float

    /// Vision-space coordinates: origin bottom-left, Y increases upward.
    init?(observation: VNHumanHandPoseObservation,
          confidenceThreshold: Float = 0.65) {
        guard observation.confidence >= confidenceThreshold else { return nil }
        do {
            let pts = try observation.recognizedPoints(.all)
            func pt(_ key: VNHumanHandPoseObservation.JointName) -> CGPoint {
                pts[key]?.location ?? .zero
            }
            wrist     = pt(.wrist)
            thumbTip  = pt(.thumbTip)
            indexTip  = pt(.indexTip)
            indexMCP  = pt(.indexMCP)
            middleTip = pt(.middleTip)
            middleMCP = pt(.middleMCP)
            ringTip   = pt(.ringTip)
            ringMCP   = pt(.ringMCP)
            littleTip = pt(.littleTip)
            littleMCP = pt(.littleMCP)
            confidence = observation.confidence
        } catch {
            return nil
        }
    }

    /// Approximate palm centre (midpoint of wrist and middle MCP).
    var palmCenter: CGPoint {
        CGPoint(x: (wrist.x + middleMCP.x) / 2,
                y: (wrist.y + middleMCP.y) / 2)
    }
}

// MARK: - Gesture State Machine

/// Ten deliberate gesture phases.
///
/// Transition rules (all require dwell/frame counts or score thresholds):
/// ```
///   disabled  → idle              : tracking re-enabled
///   idle      → handCandidate     : any valid pose detected
///   handCandidate → handEligible  : held for handCandidateDwellFrames
///   handCandidate → idle          : pose lost
///   handEligible → pointerActive  : extension score ≥ 0.45 (EMA-sustained)
///   handEligible → suppressed     : isSuppressed flag from coordinator
///   pointerActive → pinchCandidate: smoothed pinch dist < threshold
///   pointerActive → handEligible  : extension drops below 0.25
///   pointerActive → suppressed    : isSuppressed flag
///   pinchCandidate → pinching     : held for pinchDwellFrames
///   pinchCandidate → pointerActive: opened before dwell — clean cancel
///   pinching → pinchRelease       : open for releaseDwellFrames (hysteresis)
///   pinchRelease → pointerActive  : one-frame transition, auto-advances
///   suppressed → handEligible     : isSuppressed cleared + exit dwell passed
///   any → cooldown                : coordinator requests post-gesture pause
///   cooldown → handEligible       : cooldown frames elapsed
///   any → idle                    : hand lost or confidence drops
/// ```
enum SpatialGestureState: Equatable {
    case disabled          // tracking off (user toggled)
    case idle              // no hand / low confidence
    case handCandidate     // hand seen, dwell gate not yet satisfied
    case handEligible      // dwell passed, pointer not yet extended (was palmVisible)
    case pointerActive     // index extended — hover / click mode
    case pinchCandidate    // converging — dwell not yet satisfied
    case pinching          // confirmed pinch (dwell passed)
    case pinchRelease      // exactly one frame on release — triggers coordinator actions
    case suppressed        // suppressed by score / accidental motion / face
    case cooldown          // brief post-gesture pause (frames counted)
}

// MARK: - GestureClassifier

/// Converts raw `HandPose` observations into semantic `SpatialGestureState` values.
///
/// Key design principles:
/// - Every transition requires sustained evidence (dwell frames), not single-frame
///   detections.  Eliminates jitter-induced false transitions.
/// - An external `isSuppressed` flag (computed by the coordinator from
///   `HandIntentScore` + `AccidentalMotionDetector`) can force suppression of any
///   active state without resetting accumulated dwell.
/// - Pinch and release both require dwell with hysteresis gap.
/// - Suppression exit requires its own dwell so a briefly-clear hand doesn't
///   immediately regain control.
/// - A cooldown state allows a deliberate post-gesture pause.
final class GestureClassifier {

    // MARK: - Private state

    // EMA-smoothed metrics
    private var smoothedPinchDist: Float = 1.0
    private var smoothedExtension: Float = 0.0

    // Dwell counters
    private var handCandidateFrames:  Int = 0  // toward handEligible
    private var pinchCandidateFrames: Int = 0  // toward confirming pinch
    private var pinchReleaseFrames:   Int = 0  // toward confirming release
    private var suppressedExitFrames: Int = 0  // toward exiting suppressed
    private var cooldownFrames:       Int = 0  // frames remaining in cooldown

    // Published state
    private(set) var currentState: SpatialGestureState = .idle
    var currentGesture: SpatialGestureState { currentState }

    // MARK: - Classify

    /// Call every Vision frame.
    ///
    /// - Parameters:
    ///   - pose: primary hand pose (nil = no hand)
    ///   - isSuppressed: when true, hand cannot control UI (from scoring/accidental motion)
    func classify(pose: HandPose?, isSuppressed: Bool = false) -> SpatialGestureState {
        guard let p = pose else {
            return _transitionToIdle()
        }

        // ── Smooth continuous metrics ─────────────────────────────────
        let rawDist = Float(dist(p.thumbTip, p.indexTip))
        smoothedPinchDist = ema(smoothedPinchDist, rawDist,
                                Float(SpatialInteractionConfig.shared.smoothingAlpha) * 2.5)

        let rawExt = extensionScore(pose: p)
        smoothedExtension = ema(smoothedExtension, rawExt,
                                Float(SpatialInteractionConfig.shared.smoothingAlpha) * 1.5)

        let cfg = SpatialInteractionConfig.shared

        // ── State machine ─────────────────────────────────────────────
        switch currentState {

        case .disabled:
            // Stay disabled until coordinator clears the flag
            break

        case .idle:
            handCandidateFrames  = 1
            pinchCandidateFrames = 0
            pinchReleaseFrames   = 0
            currentState = .handCandidate

        case .handCandidate:
            if isSuppressed {
                // Hand detected but suppressed immediately — brief candidate reset
                handCandidateFrames = 0
                break
            }
            handCandidateFrames += 1
            if handCandidateFrames >= cfg.handCandidateDwellFrames {
                handCandidateFrames = 0
                currentState = .handEligible
            }

        case .handEligible:
            if isSuppressed {
                suppressedExitFrames = 0
                currentState = .suppressed
                break
            }
            if smoothedExtension >= 0.45 {
                currentState = .pointerActive
            }
            // Stay in handEligible until extension is sustained

        case .pointerActive:
            if isSuppressed {
                suppressedExitFrames = 0
                currentState = .suppressed
                break
            }
            if smoothedPinchDist < cfg.pinchThreshold {
                pinchCandidateFrames = 1
                currentState = .pinchCandidate
            } else if smoothedExtension < 0.25 {
                currentState = .handEligible
            }

        case .pinchCandidate:
            // Don't suppress mid-candidate — require clean exit to avoid flicker
            if smoothedPinchDist < cfg.pinchThreshold {
                pinchCandidateFrames += 1
                if pinchCandidateFrames >= cfg.pinchDwellFrames {
                    pinchCandidateFrames = 0
                    currentState = .pinching
                }
            } else {
                // Opened back up — cancel cleanly
                pinchCandidateFrames = 0
                currentState = .pointerActive
            }

        case .pinching:
            if smoothedPinchDist > cfg.pinchThreshold + cfg.pinchReleaseGap {
                pinchReleaseFrames += 1
                if pinchReleaseFrames >= cfg.pinchReleaseDwellFrames {
                    pinchReleaseFrames = 0
                    currentState = .pinchRelease
                }
            } else {
                pinchReleaseFrames = 0
            }

        case .pinchRelease:
            // One-frame state — advance to best resting state
            pinchReleaseFrames   = 0
            pinchCandidateFrames = 0
            currentState = smoothedExtension >= 0.35 ? .pointerActive : .handEligible

        case .suppressed:
            if !isSuppressed {
                suppressedExitFrames += 1
                if suppressedExitFrames >= cfg.suppressedExitDwellFrames {
                    suppressedExitFrames = 0
                    currentState = .handEligible
                }
            } else {
                suppressedExitFrames = 0
            }

        case .cooldown:
            if cooldownFrames > 0 {
                cooldownFrames -= 1
            } else {
                currentState = smoothedExtension >= 0.45 ? .pointerActive : .handEligible
            }
        }

        return currentState
    }

    // MARK: - Control

    /// Coordinator calls this to enter a brief post-gesture cooldown.
    func enterCooldown(frames: Int = 8) {
        pinchCandidateFrames = 0
        pinchReleaseFrames   = 0
        cooldownFrames       = frames
        currentState         = .cooldown
    }

    /// Coordinator calls this to disable tracking (user toggle).
    func disable() {
        currentState = .disabled
        _resetCounters()
    }

    /// Coordinator calls this to re-enable tracking after `disable()`.
    func enable() {
        if currentState == .disabled {
            currentState = .idle
        }
    }

    // MARK: - Helpers

    private func _transitionToIdle() -> SpatialGestureState {
        // Decay smoothed metrics rather than hard-resetting so re-acquisition
        // doesn't start from a stale "pinching" value.
        smoothedPinchDist = ema(smoothedPinchDist, 1.0, 0.15)
        smoothedExtension = ema(smoothedExtension, 0.0, 0.15)
        _resetCounters()
        currentState = (currentState == .disabled) ? .disabled : .idle
        return currentState
    }

    private func _resetCounters() {
        handCandidateFrames  = 0
        pinchCandidateFrames = 0
        pinchReleaseFrames   = 0
        suppressedExitFrames = 0
        cooldownFrames       = 0
    }

    /// Score 0…1 for how open / extended the hand is.
    /// Each finger contributes 0.25; a finger is "extended" when its tip is
    /// farther from the wrist than 1.15× its MCP distance.
    private func extensionScore(pose p: HandPose) -> Float {
        let fingers: [(tip: CGPoint, mcp: CGPoint)] = [
            (p.indexTip,  p.indexMCP),
            (p.middleTip, p.middleMCP),
            (p.ringTip,   p.ringMCP),
            (p.littleTip, p.littleMCP),
        ]
        var score: Float = 0
        for f in fingers {
            let tipD = Float(dist(p.wrist, f.tip))
            let mcpD = Float(dist(p.wrist, f.mcp))
            if mcpD > 0.01 { score += min(tipD / (mcpD * 1.15), 1.0) }
        }
        return score / Float(fingers.count)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func ema(_ prev: Float, _ next: Float, _ alpha: Float) -> Float {
        prev + (next - prev) * alpha
    }
}

// MARK: - GestureClassifier.reset

extension GestureClassifier {
    func reset() { _ = classify(pose: nil) }
}
