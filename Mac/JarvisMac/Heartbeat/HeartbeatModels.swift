import Foundation

// MARK: - HeartbeatItem

/// A single tracked entry on the Heartbeat — an open issue, blocker, recent win,
/// or attention-needed flag. Carries provenance and a timestamp so stale entries
/// can be aged out and the Situation Room can show "when".
struct HeartbeatItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var source: String          // e.g. "github", "proactivity", "voice", "user"
    var confidence: Double       // 0…1 (1 = certain / user-stated)
    var createdAt: Date

    init(id: UUID = UUID(),
         text: String,
         source: String = "system",
         confidence: Double = 0.8,
         createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.confidence = max(0, min(1, confidence))
        self.createdAt = createdAt
    }

    /// Age in seconds since the item was recorded.
    var ageSeconds: TimeInterval { Date().timeIntervalSince(createdAt) }
}

// MARK: - HeartbeatState

/// The living "current state" of Jarvis — the thing that should survive restarts,
/// model changes, and feature additions. This is the operational pulse described
/// in the Jarvis vision's Heartbeat / Situation Room sections:
///
/// > Tracks: current focus, active project, open issues, recent wins, confidence,
/// > blockers, attention needed. Heartbeat is continuously updated.
///
/// Persisted as JSON and hot-reloaded from disk (a living, editable runtime layer).
struct HeartbeatState: Codable, Equatable {

    /// Short label of what the user is doing right now (e.g. "writing code").
    var currentFocus: String?

    /// The dominant project the user is focused on, when one can be determined.
    var activeProject: String?

    /// Hysteresis-smoothed confidence (0…1) in `activeProject`.
    var focusConfidence: Double

    /// Things that need the user's attention now (high-priority proactive signals).
    var attentionNeeded: [HeartbeatItem]

    /// Hard blockers stalling progress.
    var blockers: [HeartbeatItem]

    /// Open issues across projects (e.g. failing builds, unresolved bugs).
    var openIssues: [HeartbeatItem]

    /// Recent wins / completed work, for momentum and morale.
    var recentWins: [HeartbeatItem]

    /// One-line summary of today's activity (from the episode timeline).
    var todaySummary: String?

    /// Rolling counters.
    var sessionCount: Int
    var interactionCount: Int

    var lastInteractionAt: Date?
    var updatedAt: Date

    init(currentFocus: String? = nil,
         activeProject: String? = nil,
         focusConfidence: Double = 0,
         attentionNeeded: [HeartbeatItem] = [],
         blockers: [HeartbeatItem] = [],
         openIssues: [HeartbeatItem] = [],
         recentWins: [HeartbeatItem] = [],
         todaySummary: String? = nil,
         sessionCount: Int = 0,
         interactionCount: Int = 0,
         lastInteractionAt: Date? = nil,
         updatedAt: Date = Date()) {
        self.currentFocus = currentFocus
        self.activeProject = activeProject
        self.focusConfidence = max(0, min(1, focusConfidence))
        self.attentionNeeded = attentionNeeded
        self.blockers = blockers
        self.openIssues = openIssues
        self.recentWins = recentWins
        self.todaySummary = todaySummary
        self.sessionCount = sessionCount
        self.interactionCount = interactionCount
        self.lastInteractionAt = lastInteractionAt
        self.updatedAt = updatedAt
    }

    /// Forward-compatible decode: every field defaults so older / partial JSON
    /// (and hand-edited files) still load. Matches the project's `decodeIfPresent`
    /// preference convention.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentFocus      = try c.decodeIfPresent(String.self, forKey: .currentFocus)
        activeProject     = try c.decodeIfPresent(String.self, forKey: .activeProject)
        focusConfidence   = try c.decodeIfPresent(Double.self, forKey: .focusConfidence) ?? 0
        attentionNeeded   = try c.decodeIfPresent([HeartbeatItem].self, forKey: .attentionNeeded) ?? []
        blockers          = try c.decodeIfPresent([HeartbeatItem].self, forKey: .blockers) ?? []
        openIssues        = try c.decodeIfPresent([HeartbeatItem].self, forKey: .openIssues) ?? []
        recentWins        = try c.decodeIfPresent([HeartbeatItem].self, forKey: .recentWins) ?? []
        todaySummary      = try c.decodeIfPresent(String.self, forKey: .todaySummary)
        sessionCount      = try c.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        interactionCount  = try c.decodeIfPresent(Int.self, forKey: .interactionCount) ?? 0
        lastInteractionAt = try c.decodeIfPresent(Date.self, forKey: .lastInteractionAt)
        updatedAt         = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        focusConfidence   = max(0, min(1, focusConfidence))
    }

    // MARK: - LLM context block

    /// A compact `[HEARTBEAT]` block for injection into the LLM system prompt.
    /// Empty string when there is nothing meaningful to report, so callers can
    /// skip it cleanly. Only non-empty fields are emitted.
    func contextBlock() -> String {
        var lines: [String] = []
        if let f = currentFocus?.nonBlank { lines.append("focus: \(f)") }
        if let p = activeProject?.nonBlank {
            let pct = Int((focusConfidence * 100).rounded())
            lines.append(focusConfidence > 0
                         ? "active_project: \(p) (\(pct)% confidence)"
                         : "active_project: \(p)")
        }
        if !attentionNeeded.isEmpty {
            lines.append("attention_needed: " + attentionNeeded.map(\.text).joined(separator: "; "))
        }
        if !blockers.isEmpty {
            lines.append("blockers: " + blockers.map(\.text).joined(separator: "; "))
        }
        if !openIssues.isEmpty {
            lines.append("open_issues: " + openIssues.prefix(5).map(\.text).joined(separator: "; "))
        }
        if !recentWins.isEmpty {
            lines.append("recent_wins: " + recentWins.prefix(5).map(\.text).joined(separator: "; "))
        }
        if let t = todaySummary?.nonBlank { lines.append("today: \(t)") }

        guard !lines.isEmpty else { return "" }
        return "[HEARTBEAT — Jarvis live state]\n"
            + lines.joined(separator: "\n")
            + "\n# This is the current operational pulse. Use it to stay grounded in what matters right now."
    }

    /// A short spoken summary for a "situation report" / "what's my status" reply.
    func situationSummary() -> String {
        var parts: [String] = []
        if let p = activeProject?.nonBlank {
            parts.append("You're focused on \(p)")
        } else if let f = currentFocus?.nonBlank {
            parts.append("Right now: \(f)")
        }
        if let first = attentionNeeded.first {
            parts.append("needs attention: \(first.text)")
        } else if let b = blockers.first {
            parts.append("blocked on \(b.text)")
        }
        if let win = recentWins.first {
            parts.append("recent win: \(win.text)")
        }
        if parts.isEmpty {
            return "Nothing pressing on the radar."
        }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Small helper

private extension String {
    /// Returns the trimmed string, or nil when blank.
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
