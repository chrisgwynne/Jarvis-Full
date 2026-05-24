import Foundation
import os

// MARK: - VisionEfficiencyController

/// Controls the camera frame rate tier for passive vision to keep CPU overhead
/// low. Frame rate adapts to context: watch mode runs fastest, idle/vacant
/// scenes suspend entirely after a quiet period.
///
/// Also provides confidence filtering to prevent rapid oscillation in the
/// presence state (e.g. flickering present/away due to lighting changes).
@MainActor
final class VisionEfficiencyController {

    static let shared = VisionEfficiencyController()

    private let log = Logger(subsystem: "com.jarvis", category: "vision.efficiency")

    // MARK: - Frame Rate Tier

    enum FrameRateTier: Int, Comparable {
        case suspended = 0   // no captures
        case minimal   = 1   // 1 fps — detect re-entry
        case low       = 3   // ~0.33 fps — ambient awareness
        case normal    = 5   // 0.2 fps — default active
        case watch     = 10  // 0.1 fps — explicit watch mode

        var intervalSeconds: Double {
            switch self {
            case .suspended: return .infinity
            case .minimal:   return 5.0
            case .low:       return 3.0
            case .normal:    return 2.0
            case .watch:     return 1.0
            }
        }

        static func < (lhs: FrameRateTier, rhs: FrameRateTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - State

    private(set) var currentTier: FrameRateTier = .suspended
    private var lastTierChange = Date.distantPast
    private var lastSignificantChange: Date?

    // MARK: - Configuration

    var suspendWhenIdleMinutes: Double = 30.0
    /// Minimum seconds before downgrading tier (prevents thrash).
    var tierDowngradeDelay: Double = 5.0

    // MARK: - Tier Control

    func recommendedTier(
        isConversing: Bool,
        isWatchActive: Bool,
        isUserPresent: Bool,
        timeSinceLastChange: TimeInterval
    ) -> FrameRateTier {
        if isWatchActive              { return .watch }
        if isConversing               { return .low }
        if isUserPresent              { return .normal }
        if timeSinceLastChange < 120  { return .low }
        if timeSinceLastChange > suspendWhenIdleMinutes * 60 { return .suspended }
        return .minimal
    }

    func updateTier(isConversing: Bool, isWatchActive: Bool, isUserPresent: Bool) {
        let elapsed = lastSignificantChange.map { Date().timeIntervalSince($0) } ?? 9999
        let recommended = recommendedTier(
            isConversing: isConversing,
            isWatchActive: isWatchActive,
            isUserPresent: isUserPresent,
            timeSinceLastChange: elapsed
        )
        guard recommended != currentTier else { return }
        // Don't thrash — require stability before downgrading
        if recommended < currentTier,
           Date().timeIntervalSince(lastTierChange) < tierDowngradeDelay { return }
        log.info("vision_tier \(self.currentTier.rawValue)→\(recommended.rawValue)")
        currentTier = recommended
        lastTierChange = Date()
    }

    var intervalSeconds: Double { currentTier.intervalSeconds }
    var shouldCapture: Bool { currentTier != .suspended }

    func recordSignificantChange() {
        lastSignificantChange = Date()
    }

    // MARK: - Confidence Filtering

    /// True when a presence change has enough evidence to commit.
    /// Requires more consecutive frames for lower confidence readings.
    func shouldCommitPresenceChange(
        from current: UserPresenceKind,
        to candidate: UserPresenceKind,
        confidence: Double,
        consecutiveFrames: Int
    ) -> Bool {
        guard candidate != current else { return false }
        let threshold: Int
        switch confidence {
        case 0.85...:  threshold = 2
        case 0.65..<0.85: threshold = 3
        default:       threshold = 5
        }
        return consecutiveFrames >= threshold
    }
}
