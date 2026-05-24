import Foundation

/// Centralises all `AssistantPhase` transitions. Every change is logged and
/// invalid transitions are warned — making it easy to spot unexpected state
/// jumps in the debug log or Debug HUD.
///
/// Use `transition(to:)` for the normal pipeline. Use `forceTransition(to:)`
/// only for error recovery and bootstrap where any source state is valid.
@MainActor
final class AssistantStateMachine {

    private(set) var phase: AssistantPhase = .idle
    private let onTransition: (AssistantPhase, AssistantPhase) -> Void

    init(onTransition: @escaping (AssistantPhase, AssistantPhase) -> Void) {
        self.onTransition = onTransition
    }

    /// Attempt a guarded transition. No-op if already at `next`.
    /// Logs a warning and returns `false` if the transition is not in the
    /// allowed set; callers that need an override should use `forceTransition`.
    @discardableResult
    func transition(to next: AssistantPhase) -> Bool {
        guard next != phase else { return true }
        let currentRaw = phase.rawValue
        let nextRaw = next.rawValue
        guard isValid(from: phase, to: next) else {
            Log.app.warning("state: rejected \(currentRaw) → \(nextRaw)")
            return false
        }
        apply(next)
        return true
    }

    /// Force a transition regardless of current state. Always logs.
    func forceTransition(to next: AssistantPhase) {
        guard next != phase else { return }
        apply(next)
    }

    // MARK: - Private

    private func apply(_ next: AssistantPhase) {
        let prev = phase
        phase = next
        let from = prev.rawValue
        let to = next.rawValue
        Log.app.info("state: \(from) → \(to)")
        onTransition(prev, next)
    }

    private func isValid(from current: AssistantPhase, to next: AssistantPhase) -> Bool {
        switch (current, next) {
        // Error is always reachable
        case (_, .error):                                return true
        // Idle is reachable from most states (reset / cleanup)
        case (.idle, _):                                 return true
        case (.error, .idle):                            return true
        case (.error, .listening):                       return true
        case (.wakeListening, .idle):                    return true
        case (.wakeListening, .listening):               return true
        case (.listening, .idle):                        return true
        case (.listening, .thinking):                    return true
        case (.thinking, .idle):                         return true
        case (.thinking, .speaking):                     return true
        case (.speaking, .idle):                         return true
        case (.speaking, .conversationalListening):      return true
        case (.speaking, .wakeListening):                return true
        case (.speaking, .bargedIn):                     return true
        case (.speaking, .listening):                    return true
        case (.bargedIn, .idle):                         return true
        case (.bargedIn, .listening):                    return true
        case (.bargedIn, .conversationalListening):      return true
        case (.conversationalListening, .listening):     return true
        case (.conversationalListening, .thinking):      return true
        case (.conversationalListening, .wakeListening): return true
        case (.conversationalListening, .idle):          return true
        default:                                         return false
        }
    }
}
