import Foundation
import CoreGraphics

// MARK: - DetectionSmoother

/// Applies confidence hysteresis and temporal EMA smoothing to tracker output.
/// Not @MainActor — it is called synchronously from ObjectTracker which is already @MainActor.
final class DetectionSmoother {

    // MARK: Per-target smoothing state

    private struct TargetSmoothing {
        /// The class that has been "confirmed" after the cooldown period.
        var confirmedClass: DetectionClass
        /// The most recent raw confidence value received from the tracker.
        var rawConfidence: Float
        /// Exponentially weighted moving average of confidence.
        var smoothedConfidence: Float
        /// Hysteresis flag — true once smoothedConfidence crossed confirmThreshold.
        var isConfirmed: Bool
        /// Counts frames since the class last changed; resets on each class change.
        var framesSinceClassChange: Int
    }

    private var states: [UUID: TargetSmoothing] = [:]

    // MARK: Thresholds

    /// Smoothed confidence must exceed this value to enter confirmed state.
    let confirmThreshold: Float = 0.60
    /// Smoothed confidence must drop below this value to leave confirmed state.
    let dropThreshold: Float = 0.35
    /// Minimum number of frames the tracker must observe the new class before it
    /// is adopted as the confirmed class (prevents flicker on noisy detections).
    let classChangeCooldown: Int = 10

    // MARK: Public API

    /// Update smoother state for a single tracked target.
    ///
    /// - Parameter target: The target to update. Its `confidence` field is overwritten
    ///   with the smoothed value, and its `cls` may be held at the previous confirmed
    ///   class if the cooldown has not yet elapsed.
    /// - Returns: `true` if the target should be rendered (confirmed or in ghost state).
    @discardableResult
    func update(target: inout TrackedTarget) -> Bool {
        let id = target.id

        // Bootstrap state for a brand-new target.
        if states[id] == nil {
            states[id] = TargetSmoothing(
                confirmedClass: target.cls,
                rawConfidence: target.confidence,
                smoothedConfidence: target.confidence,
                isConfirmed: target.confidence >= confirmThreshold,
                framesSinceClassChange: classChangeCooldown  // start as stable
            )
        }

        var state = states[id]!

        // 1. EMA smooth the raw confidence coming in from the tracker.
        state.rawConfidence = target.confidence
        state.smoothedConfidence = ema(target.confidence, state.smoothedConfidence)

        // 2. Hysteresis on the confirmed flag.
        if !state.isConfirmed && state.smoothedConfidence >= confirmThreshold {
            state.isConfirmed = true
        } else if state.isConfirmed && state.smoothedConfidence < dropThreshold {
            state.isConfirmed = false
        }

        // 3. Class change cooldown.
        //    If the tracker reports a different (non-compatible) class, start counting.
        //    Only adopt the new class once the cooldown has elapsed.
        if target.cls != state.confirmedClass &&
           !state.confirmedClass.isCompatible(with: target.cls) {
            // Increment counter; it was reset to 0 when the class first changed.
            state.framesSinceClassChange += 1
            if state.framesSinceClassChange < classChangeCooldown {
                // Keep showing the previously confirmed class until we're sure.
                target.cls = state.confirmedClass
            } else {
                // Cooldown elapsed — adopt the new class and restart counter.
                state.confirmedClass = target.cls
                state.framesSinceClassChange = 0
            }
        } else if target.cls == state.confirmedClass {
            // Class is stable — keep counter saturated so future changes start fresh.
            state.framesSinceClassChange = classChangeCooldown
        }

        // 4. Write smoothed confidence back to the target.
        target.confidence = state.smoothedConfidence

        states[id] = state

        // 5. Display if confirmed or if we are predicting (ghost).
        return state.isConfirmed || target.isGhost
    }

    // MARK: Lifecycle

    /// Remove internal state for a target that has been purged from the tracker.
    func remove(id: UUID) {
        states.removeValue(forKey: id)
    }

    /// Wipe all internal state (e.g. on camera switch or tracker reset).
    func reset() {
        states.removeAll()
    }

    // MARK: Private helpers

    /// Exponential moving average.
    /// - Parameters:
    ///   - current: The newest raw observation.
    ///   - previous: The previous smoothed value.
    ///   - alpha: Weight given to the current observation (0 = ignore, 1 = instant snap).
    private func ema(_ current: Float, _ previous: Float, alpha: Float = 0.25) -> Float {
        alpha * current + (1.0 - alpha) * previous
    }
}
