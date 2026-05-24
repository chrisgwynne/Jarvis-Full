import Foundation

// MARK: - VisionStateSummary

/// Distills the current vision state into compact text summaries suitable for
/// LLM injection and proactivity decisions.
///
/// Reads from `PersistentVisionContext` (presence/attention) as the primary
/// source. All methods are synchronous — summary building is pure text.
@MainActor
enum VisionStateSummary {

    // MARK: - Public API

    /// One-line summary for diagnostic overlays.
    static func oneLiner() -> String {
        let ctx = PersistentVisionContext.shared
        guard ctx.isFresh else { return "vision: stale" }
        return "vision: \(ctx.oneLiner)"
    }

    /// Compact context block for LLM system prompt injection.
    /// Returns empty string if no meaningful vision data is available.
    static func contextBlock() -> String {
        let ctx = PersistentVisionContext.shared
        guard ctx.isFresh && ctx.presenceKind != .unknown else { return "" }

        var lines = ["[VISION CONTEXT]"]
        lines.append("User presence: \(ctx.presenceKind.humanLabel)")
        if ctx.attentionState != .unknown {
            lines.append("Attention: \(ctx.attentionState.rawValue)")
        }
        if ctx.isDeskOccupied {
            let dur = ctx.continuousPresenceDuration
            if dur > 60 { lines.append("At desk for: \(formattedDuration(dur))") }
        }
        lines.append("(passive observation — treat as weak signal)")
        return lines.joined(separator: "\n")
    }

    /// True if the user appears to be at their desk.
    static var isUserPresent: Bool {
        let ctx = PersistentVisionContext.shared
        return ctx.isFresh && ctx.presenceKind == .present && ctx.confidenceScore >= 0.55
    }

    /// True if the desk is confirmed empty — reduce proactivity.
    static var isDeskEmpty: Bool {
        let ctx = PersistentVisionContext.shared
        return ctx.isFresh && ctx.presenceKind == .away
    }

    // MARK: - Helpers

    private static func formattedDuration(_ seconds: Double) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)min" }
        return "\(mins / 60)h \(mins % 60)min"
    }
}

private extension UserPresenceKind {
    var humanLabel: String {
        switch self {
        case .present: return "at desk"
        case .away:    return "away from desk"
        case .unknown: return "unknown"
        }
    }
}
