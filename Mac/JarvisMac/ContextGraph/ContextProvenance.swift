import Foundation

// MARK: - Provenance Entry

/// One source's contribution to a context assembly.
struct ProvenanceEntry: Codable {
    let source: ContextSource
    let nodeType: ContextNodeType
    let nodeID: UUID
    let nodeTitle: String
    let trustTier: TrustTier
    let charCount: Int
    /// Why this source was selected.
    let reason: String
}

// MARK: - Context Provenance

/// Explains exactly what went into a context assembly and why.
struct ContextProvenance {

    let nodeID: UUID
    let nodeTitle: String
    let entries: [ProvenanceEntry]
    let totalCharBudget: Int
    let usedCharBudget: Int
    let truncatedSources: [String]
    let excludedSources: [String]
    let generatedAt: Date

    var budgetUsageFraction: Double {
        totalCharBudget > 0 ? Double(usedCharBudget) / Double(totalCharBudget) : 0
    }

    /// Human-readable summary suitable for a debug log or "why did you say that?" response.
    var summary: String {
        var lines = [String]()
        lines.append("Context for '\(nodeTitle)' — \(entries.count) source(s)")
        for e in entries {
            lines.append("  • [\(e.trustTier.label)] \(e.source.displayName): \"\(e.nodeTitle)\" (\(e.charCount) chars) — \(e.reason)")
        }
        lines.append("Budget: \(usedCharBudget)/\(totalCharBudget) chars used")
        if !truncatedSources.isEmpty {
            lines.append("Truncated: \(truncatedSources.joined(separator: ", "))")
        }
        if !excludedSources.isEmpty {
            lines.append("Excluded: \(excludedSources.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Diagnostics

/// Lightweight stats snapshot for debug overlays and logging.
struct ContextGraphDiagnostics {
    let nodeCount: Int
    let edgeCount: Int
    let nodesByType: [ContextNodeType: Int]
    let edgesByType: [ContextEdgeType: Int]
    let lastIngestionAt: Date?
    let topActiveProject: String?
    let activeContinuityChainLength: Int
    let contextBudgetBySource: [String: Int]   // source.displayName → char count
    let excludedContextCount: Int
    let generatedAt: Date

    // Persistence stats
    let persistedGraphLoaded: Bool
    let lastSaveTime: Date?
    let lastPruneResult: PruneResult?
    let nodeCap: Int
    let edgeCap: Int

    // Focus state (Sprint V)
    let focusConfidence: Double
    let previousFocusProject: String?
    let rankedNodeCount: Int
    let suppressedNodeCount: Int

    // Memory-pressure diagnostics
    let graphSafeMode: Bool
    let lastRefreshDuration: TimeInterval
    /// How many times safe mode short-circuited a full refresh since launch.
    let safeModeSkipCount: Int
    /// Rough estimate: avg 300 bytes/node + 150 bytes/edge.
    var estimatedGraphBytes: Int { nodeCount * 300 + edgeCount * 150 }

    /// Single-line summary for status strips or log lines.
    var oneLiner: String {
        let age: String
        if let t = lastIngestionAt {
            let s = Int(Date().timeIntervalSince(t))
            age = s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
        } else {
            age = "never"
        }
        return "ContextGraph: \(nodeCount) nodes · \(edgeCount) edges · last ingested \(age)"
            + (topActiveProject.map { " · project: \($0)" } ?? "")
    }

    /// Focus state one-liner for the diagnostics overlay.
    var focusOneLiner: String {
        guard let project = topActiveProject, focusConfidence > 0 else {
            return "focus: none"
        }
        let pct = Int(focusConfidence * 100)
        let prev = previousFocusProject.map { " (was: \($0))" } ?? ""
        return "focus: \(project) \(pct)%\(prev) · ranked: \(rankedNodeCount) · suppressed: \(suppressedNodeCount)"
    }

    /// Short persistence status line.
    var persistenceOneLiner: String {
        var parts = [String]()
        parts.append(persistedGraphLoaded ? "loaded from disk" : "cold start")
        if let t = lastSaveTime {
            let s = Int(Date().timeIntervalSince(t))
            parts.append("saved \(s < 60 ? "\(s)s" : "\(s / 60)m") ago")
        }
        if let p = lastPruneResult, !p.isEmpty {
            parts.append("pruned \(p.nodesRemoved)N/\(p.edgesRemoved)E")
        }
        if safeModeSkipCount > 0 {
            parts.append("safe-mode skips: \(safeModeSkipCount)")
        }
        return parts.joined(separator: " · ")
    }
}
