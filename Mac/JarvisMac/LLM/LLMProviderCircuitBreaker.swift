import Foundation

/// Prevents hammering a degraded LLM provider endpoint.
///
/// After `maxConsecutiveFailures` failures within `windowSeconds`, the
/// provider's circuit opens and `isOpen(_:)` returns `true` for
/// `cooldownSeconds`, during which that provider is skipped.
/// A single success fully resets the counter.
///
/// Usage in `LLMRouter.complete()`:
///   - filter `selectChain()` with `!isOpen(provider.id)`
///   - call `recordSuccess` / `recordFailure` after each attempt
@MainActor
final class LLMProviderCircuitBreaker {

    private struct ProviderState {
        var failureCount: Int = 0
        var lastFailure: Date?
        var degradedSince: Date?
    }

    private var providers: [String: ProviderState] = [:]

    /// Number of consecutive failures before circuit opens.
    let maxConsecutiveFailures: Int = 2
    /// Window in which failures are counted (reset if last failure was older).
    let windowSeconds: TimeInterval = 60
    /// How long a degraded provider is skipped before one retry is allowed.
    let cooldownSeconds: TimeInterval = 30

    // MARK: - Queries

    /// Returns `true` when the circuit is open — provider should be skipped.
    func isOpen(_ id: String) -> Bool {
        guard var st = providers[id], let degradedSince = st.degradedSince else { return false }
        if Date().timeIntervalSince(degradedSince) >= cooldownSeconds {
            // Cooldown elapsed — allow one probe attempt.
            st.degradedSince = nil
            st.failureCount  = 0
            providers[id] = st
            Log.llm.info("circuit_reset provider=\(id)")
            return false
        }
        return true
    }

    var degradedProviderIDs: [String] {
        providers.compactMap { id, st in st.degradedSince != nil ? id : nil }
    }

    var allCircuitsOpen: Bool {
        let known = ["minimax", "llama_cpp"]
        return !known.isEmpty && known.allSatisfy { isOpen($0) }
    }

    // MARK: - Recording

    func recordSuccess(_ id: String) {
        if providers[id]?.failureCount ?? 0 > 0 {
            Log.llm.info("circuit_success_reset provider=\(id)")
        }
        providers[id] = ProviderState()
    }

    func recordFailure(_ id: String) {
        var st = providers[id] ?? ProviderState()
        // Reset stale count if last failure was outside the window.
        if let last = st.lastFailure, Date().timeIntervalSince(last) > windowSeconds {
            st.failureCount = 0
        }
        st.failureCount += 1
        st.lastFailure = Date()
        if st.failureCount >= maxConsecutiveFailures, st.degradedSince == nil {
            st.degradedSince = Date()
            Log.llm.warning("circuit_opened provider=\(id) after \(st.failureCount) failures")
        }
        providers[id] = st
    }
}
