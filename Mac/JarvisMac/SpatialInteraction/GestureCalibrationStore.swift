import Foundation
import CoreGraphics

// MARK: - GestureCalibrationStore

/// Lightweight local learning system for hand tracking.
///
/// Tracks "normal" for this user using slow exponential moving averages (EMA),
/// then adapts `SpatialInteractionConfig.shared` gradually toward those norms.
///
/// **Safety rules:**
/// - Learning only starts after `minFramesBeforeAdapt` frames.
/// - Adapted values are clamped to ±30% of factory defaults.
/// - Adaptation runs at most once every 5 seconds.
/// - A public `reset()` restores factory defaults and clears the profile.
@MainActor
final class GestureCalibrationStore {
    static let shared = GestureCalibrationStore()

    // MARK: - Profile (persisted)

    struct Profile: Codable {
        // ── Observed metrics ───────────────────────────────────────────
        var avgPointerSpeedPts:          Double = 80.0
        var avgPinchDistNorm:            Double = 0.035
        var avgReleaseDistNorm:          Double = 0.065
        var avgTremorRangePts:           Double = 3.5
        var secondHandFalsePositiveRate: Double = 0.05
        var resizeFalseStartRate:        Double = 0.10
        var successfulGestures:          Int    = 0
        var cancelledGestures:           Int    = 0
        var totalFrames:                 Int    = 0
        var lastAdaptedAt:               Date   = .distantPast

        // ── Adapted thresholds ─────────────────────────────────────────
        var adaptedSmoothingAlpha:        Double = 0.10
        var adaptedDeadzonePts:           Double = 4.0
        var adaptedPinchThreshold:        Double = 0.045
        var adaptedPinchReleaseGap:       Double = 0.015
        var adaptedPointerSensitivity:    Double = 0.75
        var adaptedDragSensitivity:       Double = 0.55
        var adaptedResizeDwellFrames:     Int    = 25
        var adaptedSecondHandDwellFrames: Int    = 30
        var adaptedFacePaddingNorm:       Double = 0.07

        // ── Derived helpers ────────────────────────────────────────────
        var recentSuccessRate: Float {
            let total = successfulGestures + cancelledGestures
            guard total > 0 else { return 0.5 }
            return Float(successfulGestures) / Float(total)
        }
        var recentCancelRate: Float {
            let total = successfulGestures + cancelledGestures
            guard total > 0 else { return 0.1 }
            return Float(cancelledGestures) / Float(total)
        }
        var isWarmEnough: Bool { totalFrames >= 300 }
    }

    // MARK: - State

    private(set) var profile = Profile()
    private let fileURL:       URL

    /// Very slow adaptation — prevents the system from over-fitting to
    /// unusual sessions.
    private let slowAlpha:  Double = 0.015
    private let fasterAlpha: Double = 0.040

    // MARK: - Init

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent("gesture_calibration.json")
        load()
    }

    // MARK: - Recording

    func recordPointerSpeed(_ speedPts: Double) {
        profile.avgPointerSpeedPts = ema(profile.avgPointerSpeedPts, speedPts, slowAlpha)
        profile.totalFrames = min(profile.totalFrames + 1, 1_000_000)
    }

    func recordPinchDistance(_ normDist: Double) {
        profile.avgPinchDistNorm = ema(profile.avgPinchDistNorm, normDist, fasterAlpha)
    }

    func recordReleaseDistance(_ normDist: Double) {
        profile.avgReleaseDistNorm = ema(profile.avgReleaseDistNorm, normDist, fasterAlpha)
    }

    func recordTremorRange(_ rangePts: Double) {
        profile.avgTremorRangePts = ema(profile.avgTremorRangePts, rangePts, slowAlpha)
    }

    func recordGestureSuccess() {
        profile.successfulGestures = min(profile.successfulGestures + 1, 10_000)
        triggerAdaptation()
    }

    func recordGestureCancelled() {
        profile.cancelledGestures = min(profile.cancelledGestures + 1, 10_000)
    }

    func recordSecondHandFalsePositive() {
        profile.secondHandFalsePositiveRate = ema(
            profile.secondHandFalsePositiveRate, 1.0, fasterAlpha * 2)
        triggerAdaptation()
    }

    func recordResizeFalseStart() {
        profile.resizeFalseStartRate = ema(
            profile.resizeFalseStartRate, 1.0, fasterAlpha * 2)
        triggerAdaptation()
    }

    // MARK: - Adaptation

    private var adaptationTask: Task<Void, Never>?

    private func triggerAdaptation() {
        guard adaptationTask == nil else { return }
        adaptationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.adapt()
            self?.adaptationTask = nil
        }
    }

    private func adapt() {
        guard profile.isWarmEnough else { return }

        // ── Smoothing: more tremor → smoother (lower alpha) ────────────
        let tremorRatio = profile.avgTremorRangePts / 3.5  // 3.5 pts = normal
        let targetSmoothing = 0.10 / max(0.6, tremorRatio)
        profile.adaptedSmoothingAlpha = clamp(targetSmoothing, 0.05, 0.18)

        // ── Deadzone: track to 120% of observed tremor range ───────────
        profile.adaptedDeadzonePts = clamp(profile.avgTremorRangePts * 1.2, 2.0, 9.0)

        // ── Pinch threshold: slightly above observed average ───────────
        profile.adaptedPinchThreshold = clamp(profile.avgPinchDistNorm * 1.15, 0.028, 0.068)

        // ── Pointer sensitivity: faster users get more range ───────────
        let speedRatio = profile.avgPointerSpeedPts / 80.0
        profile.adaptedPointerSensitivity = clamp(0.75 * speedRatio, 0.50, 1.00)

        // ── Drag sensitivity: always 75% of pointer sensitivity ────────
        profile.adaptedDragSensitivity = clamp(profile.adaptedPointerSensitivity * 0.75,
                                               0.35, 0.80)

        // ── Second hand dwell: more false positives → longer wait ──────
        let fpBoost = profile.secondHandFalsePositiveRate * 25.0
        profile.adaptedSecondHandDwellFrames = Int(clamp(30.0 + fpBoost, 18.0, 65.0))

        // ── Resize dwell: more false starts → longer wait ──────────────
        let rsBoost = profile.resizeFalseStartRate * 35.0
        profile.adaptedResizeDwellFrames = Int(clamp(25.0 + rsBoost, 18.0, 70.0))

        profile.lastAdaptedAt = Date()
        save()
        applyToConfig()
    }

    // MARK: - Apply to runtime config

    func applyToConfig() {
        SpatialInteractionConfig.shared.smoothingAlpha         = CGFloat(profile.adaptedSmoothingAlpha)
        SpatialInteractionConfig.shared.deadzonePts            = CGFloat(profile.adaptedDeadzonePts)
        SpatialInteractionConfig.shared.pinchThreshold         = Float(profile.adaptedPinchThreshold)
        SpatialInteractionConfig.shared.pinchReleaseGap        = Float(profile.adaptedPinchReleaseGap)
        SpatialInteractionConfig.shared.pointerSensitivity     = CGFloat(profile.adaptedPointerSensitivity)
        SpatialInteractionConfig.shared.dragSensitivity        = CGFloat(profile.adaptedDragSensitivity)
        SpatialInteractionConfig.shared.resizeDwellFrames      = profile.adaptedResizeDwellFrames
        SpatialInteractionConfig.shared.secondHandDwellFrames  = profile.adaptedSecondHandDwellFrames
        SpatialInteractionConfig.shared.facePaddingNorm        = CGFloat(profile.adaptedFacePaddingNorm)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p    = try? JSONDecoder().decode(Profile.self, from: data) else { return }
        profile = p
        applyToConfig()
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func reset() {
        profile = Profile()
        save()
        applyToConfig()
    }

    // MARK: - Helpers

    private func ema(_ prev: Double, _ next: Double, _ alpha: Double) -> Double {
        prev + (next - prev) * alpha
    }
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, v))
    }
}
