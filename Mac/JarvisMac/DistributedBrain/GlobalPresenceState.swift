import Foundation
import Observation

// MARK: - GlobalPresenceState

/// Observable singleton that exposes the fused global presence state across all devices.
/// Distinct from GlobalPresenceAggregator (raw per-device snapshots) and
/// GlobalAttentionCoordinator (Mac-side attention arbiter).
///
/// Refreshed on every presence.update from any device and on attention coordinator refresh.
/// SwiftUI views and LLM context builders observe this rather than the lower-level stores.
@Observable
@MainActor
final class GlobalPresenceState {

    static let shared = GlobalPresenceState()

    // MARK: - Snapshot fields (updated by refresh())

    private(set) var lastRefreshedAt: Date = Date()
    private(set) var attentionState: GlobalAttentionCoordinator.GlobalAttentionState = .idle
    private(set) var windowsPresence: PresenceSnapshot? = nil
    private(set) var anyDevicePresent: Bool = false
    private(set) var connectedDeviceCount: Int = 0

    // MARK: - Computed conveniences

    var isAnyDeviceInCodingFlow: Bool {
        GlobalPresenceAggregator.shared.allPresence.contains { $0.attentionLevel == .codingFlow }
    }

    var isAnyDeviceInMeeting: Bool {
        GlobalPresenceAggregator.shared.allPresence.contains { $0.attentionLevel == .meeting }
    }

    var verbosityHint: String? {
        GlobalAttentionCoordinator.shared.verbosityHint()
    }

    var interruptibilityScore: Double {
        GlobalAttentionCoordinator.shared.interruptibilityScore(urgency: .normal)
    }

    // MARK: - Refresh

    /// Pull fresh values from the underlying stores.
    /// Called automatically on every presence.update and attention state change.
    func refresh() {
        lastRefreshedAt      = Date()
        attentionState       = GlobalAttentionCoordinator.shared.currentState
        windowsPresence      = GlobalPresenceAggregator.shared.windowsPresence
        anyDevicePresent     = GlobalPresenceAggregator.shared.anyDeviceHasUserPresent
        connectedDeviceCount = DistributedBrainDiagnostics.shared.connectedDevices
            .filter(\.isConnected).count
    }

    // MARK: - LLM context block

    /// Returns a compact block for LLM system prompt injection, or "" when no devices present.
    func contextBlock() -> String {
        guard anyDevicePresent || windowsPresence != nil else { return "" }
        var lines = ["[GLOBAL PRESENCE STATE]"]
        lines.append("attention: \(attentionState.rawValue)")
        if let wp = windowsPresence {
            lines.append("windows: \(wp.contextOneLiner)")
            lines.append("coding_flow: \(wp.attentionLevel == .codingFlow)")
        }
        if let hint = verbosityHint {
            lines.append("verbosity_hint: \(hint)")
        }
        return lines.joined(separator: "\n")
    }
}
