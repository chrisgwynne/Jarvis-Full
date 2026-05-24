import Foundation
import Combine

// MARK: - Attention State

/// The attention state drives the entire spatial overlay lifecycle.
///
/// Transitions:
///   idle → activating   : stable open palm detected
///   activating → active : palm held for activationThreshold
///   active → deactivating : palm lost
///   deactivating → idle  : fade-out timer expires
///   activating → idle    : palm lost before threshold
/// Distinct from `AttentionState` (the app-level attention model).
/// This is purely for the spatial interaction overlay lifecycle.
enum SpatialAttentionState: Equatable {
    case idle
    case activating(progress: Double)   // 0…1 fill while waiting for hold
    case active
    case deactivating(progress: Double) // 1→0 fade while timing out
}

// MARK: - AttentionStateMachine

/// Pure state machine — no UI, no timers of its own.
/// Drive it by calling `update(palmDetected:)` every frame.
@MainActor
final class AttentionStateMachine: ObservableObject {

    // MARK: Configuration

    /// How long a stable palm must be held before going active (seconds).
    var activationThreshold: TimeInterval = 0.35

    /// Grace period after palm is lost before fading out (seconds).
    var deactivationTimeout: TimeInterval = 1.0

    // MARK: Published state

    @Published private(set) var state: SpatialAttentionState = .idle

    /// Convenience: whether the overlay should be visible at all.
    var isOverlayVisible: Bool {
        switch state {
        case .idle: return false
        default:    return true
        }
    }

    /// 0…1 opacity multiplier for smooth fades.
    var overlayOpacity: Double {
        switch state {
        case .idle:                       return 0
        case .activating(let p):          return p * 0.6   // partial during activation
        case .active:                     return 1.0
        case .deactivating(let p):        return p
        }
    }

    // MARK: Private tracking

    private var palmHeldSince:   Date?
    private var palmLostSince:   Date?

    // MARK: Update — call every frame

    func update(palmDetected: Bool, at now: Date = Date()) {
        switch state {

        case .idle:
            if palmDetected {
                palmHeldSince = now
                state = .activating(progress: 0)
            }

        case .activating:
            if palmDetected {
                let held = now.timeIntervalSince(palmHeldSince ?? now)
                let progress = min(held / activationThreshold, 1.0)
                if progress >= 1.0 {
                    state = .active
                } else {
                    state = .activating(progress: progress)
                }
            } else {
                palmHeldSince = nil
                state = .idle
            }

        case .active:
            if !palmDetected {
                palmLostSince = now
                state = .deactivating(progress: 1.0)
            }

        case .deactivating:
            if palmDetected {
                // Palm returned — jump back to active immediately.
                palmLostSince = nil
                state = .active
            } else {
                let lost = now.timeIntervalSince(palmLostSince ?? now)
                let remaining = max(0, 1.0 - lost / deactivationTimeout)
                if remaining <= 0 {
                    palmLostSince = nil
                    state = .idle
                } else {
                    state = .deactivating(progress: remaining)
                }
            }
        }
    }

    func reset() {
        palmHeldSince = nil
        palmLostSince = nil
        state = SpatialAttentionState.idle
    }
}
