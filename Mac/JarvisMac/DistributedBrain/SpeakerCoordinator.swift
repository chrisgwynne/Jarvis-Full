import Foundation

// MARK: - SpeakerCoordinator

/// Enforces the global single-speaker guarantee across all surfaces.
/// Only ONE device may produce audio at a time. Lease acquisition is
/// first-come-first-served; preemption requires a higher interruptionGeneration.
///
/// Architecture law: Windows NEVER self-grants a lease. It must request one
/// from Mac and wait for the granted response before speaking.
@MainActor
final class SpeakerCoordinator {

    static let shared = SpeakerCoordinator()

    // MARK: - State

    private(set) var currentLease: SpeakerLease?
    private var interruptionGeneration: Int = 0

    // Callbacks — wired by JarvisController so the coordinator can notify SSE clients.
    var onLeaseAcquired: ((SpeakerLease) -> Void)?
    var onLeaseReleased: ((String) -> Void)?     // deviceId
    var onLeasePreempted: ((SpeakerLease, String) -> Void)?  // old lease, preemptor deviceId

    // MARK: - Acquire

    /// Attempts to acquire the speaker lease for `deviceId`.
    /// Returns the granted lease on success, nil if another device holds an unexpired lease.
    @discardableResult
    func acquire(deviceId: String, speechId: String, expectedDurationSeconds: Double) -> SpeakerLease? {
        // Release expired lease automatically
        if let existing = currentLease, existing.isExpired {
            currentLease = nil
        }

        guard currentLease == nil else { return nil }

        let lease = SpeakerLease(
            ownerDeviceId: deviceId,
            acquiredAt: Date(),
            expectedDurationSeconds: expectedDurationSeconds,
            speechId: speechId,
            interruptionGeneration: interruptionGeneration
        )
        currentLease = lease
        onLeaseAcquired?(lease)
        return lease
    }

    // MARK: - Release

    /// Releases the lease held by `deviceId` for `speechId`. No-op if lease doesn't match.
    func release(deviceId: String, speechId: String) {
        guard let lease = currentLease,
              lease.ownerDeviceId == deviceId,
              lease.speechId == speechId else { return }
        currentLease = nil
        onLeaseReleased?(deviceId)
    }

    /// Releases whatever lease is active — used on session end or emergency stop.
    func forceRelease() {
        let prevDeviceId = currentLease?.ownerDeviceId
        currentLease = nil
        if let d = prevDeviceId { onLeaseReleased?(d) }
    }

    // MARK: - Interrupt

    /// Preempts the current lease on behalf of `interruptorDeviceId`.
    /// Only Mac may preempt — Windows cannot self-escalate.
    /// Returns true if preemption succeeded.
    @discardableResult
    func interrupt(by interruptorDeviceId: String) -> Bool {
        guard interruptorDeviceId == DistributedOrchestrationEngine.macDeviceId else {
            return false   // Windows NEVER self-grants authority to interrupt
        }
        guard let old = currentLease else { return false }
        interruptionGeneration += 1
        onLeasePreempted?(old, interruptorDeviceId)
        currentLease = nil
        return true
    }

    // MARK: - Query

    func isOnlyAllowedSpeaker(_ deviceId: String) -> Bool {
        guard let lease = currentLease else { return false }
        return lease.ownerDeviceId == deviceId && !lease.isExpired
    }

    var isIdle: Bool { currentLease == nil || currentLease?.isExpired == true }

    var oneLiner: String {
        guard let lease = currentLease, !lease.isExpired else { return "idle" }
        let elapsed = Int(Date().timeIntervalSince(lease.acquiredAt))
        return "\(lease.ownerDeviceId) speaking (\(elapsed)s)"
    }
}
