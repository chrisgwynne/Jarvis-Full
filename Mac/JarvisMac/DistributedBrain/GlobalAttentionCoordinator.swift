import Foundation

// MARK: - GlobalAttentionCoordinator

/// Fuses Mac ambient state + Windows sidecar presence into a single global
/// attention state used by the orchestration and proactivity layers to decide
/// verbosity, interruptibility, and routing.
@MainActor
final class GlobalAttentionCoordinator {

    static let shared = GlobalAttentionCoordinator()

    // MARK: - Global state

    enum GlobalAttentionState: String, Sendable {
        case idle           // nobody active
        case macActive      // user at Mac, normal session
        case windowsActive  // user at Windows surface
        case bothActive     // dual-surface session
        case codingFlow     // deep focus — reduce everything
        case meeting        // in a call — near-silent
        case transitioning  // switching apps / confused
    }

    private(set) var currentState: GlobalAttentionState = .idle
    private(set) var lastTransitionAt: Date = Date()
    private var transitionHistory: [(from: GlobalAttentionState, to: GlobalAttentionState, at: Date)] = []

    // Callbacks wired by JarvisController.
    var isMacListeningProvider: (() -> Bool)?
    var isMacSpeakingProvider: (() -> Bool)?

    // MARK: - Update

    /// Called periodically (e.g. every 5s) or on relevant SystemBus events.
    func refresh() {
        let newState = computeState()
        if newState != currentState {
            transitionHistory.append((from: currentState, to: newState, at: Date()))
            if transitionHistory.count > 20 { transitionHistory.removeFirst() }
            currentState = newState
            lastTransitionAt = Date()
        }
    }

    // MARK: - Interruptibility

    /// Score 0–1. Higher = more interruptible.
    func interruptibilityScore(urgency: ProactiveUrgency) -> Double {
        let base: Double
        switch currentState {
        case .idle:           base = 0.9
        case .macActive:      base = 0.75
        case .windowsActive:  base = 0.60
        case .bothActive:     base = 0.65
        case .codingFlow:     base = 0.20
        case .meeting:        base = 0.10
        case .transitioning:  base = 0.50
        }
        let urgencyBonus: Double
        switch urgency {
        case .critical: urgencyBonus = 0.40
        case .high:     urgencyBonus = 0.20
        case .normal:   urgencyBonus = 0.0
        case .low:      urgencyBonus = -0.10
        }
        return min(1.0, max(0.0, base + urgencyBonus))
    }

    // MARK: - Verbosity hint

    func verbosityHint() -> String? {
        switch currentState {
        case .codingFlow: return "User is in deep focus. Respond in one sentence."
        case .meeting:    return "User is in a meeting. Keep response silent or one word."
        case .transitioning: return "User is task-switching. Be very brief."
        default:          return nil
        }
    }

    // MARK: - Diagnostics

    var oneLiner: String { "\(currentState.rawValue) (since \(Int(-lastTransitionAt.timeIntervalSinceNow))s)" }

    // MARK: - Private

    private func computeState() -> GlobalAttentionState {
        let macListening = isMacListeningProvider?() ?? false
        let macSpeaking  = isMacSpeakingProvider?() ?? false
        let macActive    = macListening || macSpeaking

        let windowsSnap  = GlobalPresenceAggregator.shared.windowsPresence
        let windowsUser  = windowsSnap?.isUserPresent ?? false
        let wAttention   = windowsSnap?.attentionLevel ?? .idle

        if wAttention == .meeting { return .meeting }
        if wAttention == .codingFlow { return .codingFlow }

        if macActive && windowsUser { return .bothActive }
        if macActive { return .macActive }
        if windowsUser { return .windowsActive }
        return .idle
    }
}
