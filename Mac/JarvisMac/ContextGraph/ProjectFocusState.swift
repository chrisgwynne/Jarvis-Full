import Foundation

// MARK: - FocusTransition

/// Records a single focus change event for diagnostics.
struct FocusTransition {
    let from:       String?
    let to:         String?
    let at:         Date
    let confidence: Double
    let reason:     String
}

// MARK: - FocusContext

/// The result of `ProjectRelationshipIndex.activeFocusContext()`.
///
/// Contains the ranked node candidates and a stable focus determination.
/// Callers (e.g. `JarvisAnswerComposer`) use `rankedNodes` to select context
/// for LLM injection and `dominantProject` for the header line.
struct FocusContext {
    /// The currently dominant project, or nil if no confident focus exists.
    let dominantProject: String?
    /// Hysteresis-smoothed confidence in the dominant project (0–1).
    let confidence: Double
    /// All ranked context-node candidates (up to 10), high → low.
    let rankedNodes: [NodeScore]
    /// Human-readable explanation for diagnostics and "why did you say that?" replies.
    let reason: String
}

// MARK: - ProjectFocusState

/// Tracks which project the user is currently focused on with hysteresis.
///
/// **Hysteresis design**
///
/// Rapid app/context switches would cause focus to oscillate without a
/// stabilising mechanism.  `ProjectFocusState` implements two guards:
///
/// 1. *Incumbent bonus* — the current focus project receives a score boost
///    (`incumbentBonus = 0.15`) before the comparison, so a challenger must
///    clearly outperform it.
///
/// 2. *Change threshold* — even after the incumbent bonus, a challenger must
///    exceed the adjusted incumbent score by `changeThreshold = 0.12` to
///    trigger a focus change.  Together these require an ~27-point confidence
///    lead before focus shifts.
///
/// Focus changes are recorded in `recentTransitions` (capped at 10 entries)
/// and exposed through `whyFocused(project:)` for diagnostics.
@MainActor
final class ProjectFocusState {

    // MARK: - State

    private(set) var currentFocus:      String?  = nil
    private(set) var currentConfidence: Double   = 0
    private(set) var previousFocus:     String?  = nil
    private(set) var focusStartedAt:    Date?    = nil
    private(set) var recentTransitions: [FocusTransition] = []

    // MARK: - Hysteresis Parameters

    /// Bonus added to the incumbent project's raw score.
    let incumbentBonus:  Double = 0.15
    /// Minimum raw score required to claim focus.
    let minConfidence:   Double = 0.35
    /// Minimum score delta above the adjusted incumbent to trigger a change.
    let changeThreshold: Double = 0.12

    private let maxTransitions = 10

    // MARK: - Computed

    var focusDuration: TimeInterval {
        guard let start = focusStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Update

    /// Feed project score candidates from the latest `refresh()`.
    ///
    /// Applies the incumbent bonus and change threshold before updating state.
    /// This method is the only write path — all other accesses are reads.
    func update(candidates: [(project: String, score: Double)]) {
        guard !candidates.isEmpty else {
            if currentFocus != nil {
                recordTransition(to: nil, confidence: 0, reason: "no candidates")
                currentFocus      = nil
                currentConfidence = 0
            }
            return
        }

        // Apply incumbent bonus to the current focus before comparison
        let adjusted = candidates.map { c -> (String, Double) in
            c.project == currentFocus
                ? (c.project, min(c.score + incumbentBonus, 1.0))
                : c
        }
        guard let best = adjusted.max(by: { $0.1 < $1.1 }) else { return }

        guard best.1 >= minConfidence else {
            if currentFocus != nil {
                let reason = "score \(String(format: "%.2f", best.1)) < threshold \(minConfidence)"
                recordTransition(to: nil, confidence: 0, reason: reason)
                currentFocus      = nil
                currentConfidence = 0
            }
            return
        }

        if best.0 != currentFocus {
            let delta = best.1 - currentConfidence
            guard delta >= changeThreshold else { return }
            let reason = "\(best.0) delta=\(String(format: "%.2f", delta)) above threshold"
            recordTransition(to: best.0, confidence: best.1, reason: reason)
            previousFocus     = currentFocus
            currentFocus      = best.0
            currentConfidence = best.1
            focusStartedAt    = Date()
        } else {
            // Incumbent stays — smooth confidence update
            currentConfidence = best.1
        }
    }

    // MARK: - Queries

    func topProject() -> String? { currentFocus }

    func recentProjects(limit: Int = 5) -> [String] {
        var seen   = Set<String>()
        var result = [String]()
        for t in recentTransitions {
            guard let p = t.to, !seen.contains(p) else { continue }
            seen.insert(p)
            result.append(p)
            if result.count >= limit { break }
        }
        return result
    }

    func whyFocused(project: String) -> String {
        guard project == currentFocus else {
            return "'\(project)' is not the current focus"
        }
        if let t = recentTransitions.first(where: { $0.to == project }) {
            let elapsed = Int(Date().timeIntervalSince(t.at))
            let ago = elapsed < 60 ? "\(elapsed)s ago" : "\(elapsed / 60)m ago"
            return "Focused on '\(project)' since \(ago) (\(t.reason))"
        }
        let pct = Int(currentConfidence * 100)
        return "Focus: '\(project)' at \(pct)% confidence (stable)"
    }

    // MARK: - Private

    private func recordTransition(to: String?, confidence: Double, reason: String) {
        let t = FocusTransition(
            from:       currentFocus,
            to:         to,
            at:         Date(),
            confidence: confidence,
            reason:     reason
        )
        recentTransitions.insert(t, at: 0)
        if recentTransitions.count > maxTransitions {
            recentTransitions = Array(recentTransitions.prefix(maxTransitions))
        }
    }
}
