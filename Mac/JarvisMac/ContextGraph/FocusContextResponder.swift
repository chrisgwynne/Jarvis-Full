import Foundation

// MARK: - FocusContextResponder

/// Builds natural-language spoken answers for focus-awareness voice commands.
///
/// All methods are `@MainActor` because they read `@MainActor`-isolated graph state.
/// Methods produce short TTS-safe strings (1–3 sentences).  Return an empty string
/// when there is insufficient graph data so callers can fall back to a ResponseKey.
@MainActor
enum FocusContextResponder {

    // MARK: - "What am I working on?" (graph-enriched)

    /// Combines graph-stable focus, task thread summary, and top-ranked context node
    /// into a concise spoken answer.
    ///
    /// Returns `""` when neither a focus project nor an active thread exists.
    static func workingSummary(
        graphIndex:   ProjectRelationshipIndex,
        threadEngine: TaskThreadEngine,
        concise:      Bool = false
    ) -> String {
        let focusCtx = graphIndex.activeFocusContext()
        var parts    = [String]()

        if let project = focusCtx.dominantProject, focusCtx.confidence > 0.40 {
            let pct = Int(focusCtx.confidence * 100)
            parts.append("Graph context suggests you're focused on \(project) at \(pct)% confidence.")
        }

        let thread = threadEngine.currentThread ?? threadEngine.threads.first
        if let summary = thread?.summary, !summary.isEmpty {
            parts.append(summary)
        }

        if !concise, let top = focusCtx.rankedNodes
            .first(where: { $0.node.type != .project && $0.total > 0.40 }) {
            parts.append("Strongest signal: \(top.node.title).")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - "Where did I leave off?"

    /// Returns a spoken "last session" summary combining thread history and continuity chain.
    ///
    /// Returns `""` when no threads or context nodes exist.
    static func leftOffSummary(
        graphIndex:   ProjectRelationshipIndex,
        threadEngine: TaskThreadEngine
    ) -> String {
        var parts = [String]()

        // Most recent archived thread (not necessarily the active one)
        let recentThread = threadEngine.threads.first ?? threadEngine.currentThread
        if let thread = recentThread {
            let ago  = thread.spokenTimeAgo
            let desc = ago.isEmpty ? thread.summary : "Last session \(ago): \(thread.summary)"
            if !desc.isEmpty { parts.append(desc) }
        }

        // Top non-project node from the continuity chain
        let chain = graphIndex.activeContinuityChain(limit: 3)
        if let related = chain.first(where: { $0.type == .memory || $0.type == .obsidianNote }) {
            parts.append("Related: \(related.title).")
        }

        if let project = graphIndex.activeFocusContext().dominantProject {
            parts.append("Project: \(project).")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - "Why do you think that?"

    /// Explains the graph-inferred project focus using ranked evidence and provenance.
    ///
    /// Always returns a non-empty string — degrades gracefully when focus is unknown.
    static func whyFocused(graphIndex: ProjectRelationshipIndex) -> String {
        let focusCtx = graphIndex.activeFocusContext()
        let diag     = graphIndex.diagnostics

        guard let project = focusCtx.dominantProject else {
            let count = diag.nodeCount
            return "I don't have a confident project focus right now. "
                 + "I've tracked \(count) context node\(count == 1 ? "" : "s") "
                 + "but none strongly point to a single project yet."
        }

        let pct  = Int(focusCtx.confidence * 100)
        var parts = [String]()
        parts.append("I'm \(pct)% confident you're focused on \(project).")

        let evidence = focusCtx.rankedNodes
            .filter { $0.node.type != .project }
            .prefix(3)
            .map    { "\($0.node.title) (\($0.node.trustTier.label))" }
        if !evidence.isEmpty {
            parts.append("Supporting: \(evidence.joined(separator: "; ")).")
        }

        if !focusCtx.reason.isEmpty, focusCtx.reason != "no dominant project detected" {
            parts.append(focusCtx.reason + ".")
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - FocusAwarenessDocContributor

/// `DocumentationContributor` that exposes the focus-awareness commands in the
/// living help system.  Registered by JarvisController during bootstrap.
@MainActor
final class FocusAwarenessDocContributor: DocumentationContributor {

    let id = "context.focus_awareness"
    private let graphIndex: ProjectRelationshipIndex

    init(graphIndex: ProjectRelationshipIndex) {
        self.graphIndex = graphIndex
    }

    func section() -> DocumentationSection? {
        let diag        = graphIndex.diagnostics
        let nodeCount   = diag.nodeCount
        let hasFocus    = diag.focusConfidence > 0
        let focusLabel  = diag.topActiveProject ?? "none"
        let subtitle    = hasFocus
            ? "Active focus: \(focusLabel) (\(Int(diag.focusConfidence * 100))% confidence) · \(nodeCount) nodes"
            : "No focus detected yet · \(nodeCount) context nodes tracked"

        return DocumentationSection(
            id:       id,
            category: .diagnostics,
            title:    "Focus Awareness & Context Graph",
            subtitle: subtitle,
            bodyMarkdown: """
            Jarvis tracks what project you are focused on by building a context graph from \
            task threads, memories, Obsidian notes, GitHub notifications, and Todoist tasks.

            Focus is stabilised with hysteresis — Jarvis requires a clear lead before switching \
            between projects to avoid noise from brief app switches.

            **Confidence scores** reflect how strongly the graph's ranked signals agree on a project.

            **Limitations:**
            - Focus is inferred, not guaranteed.
            - Improves as more signals accumulate over time.
            - Privacy-blocked apps (password managers, incognito windows) are excluded.
            - No autonomous actions — Jarvis only reports, never acts on focus state.
            """,
            examples: [
                .init(phrase: "What am I working on?"),
                .init(phrase: "Where did I leave off?"),
                .init(phrase: "What project am I focused on?"),
                .init(phrase: "Why do you think that?"),
                .init(phrase: "Show focus"),
                .init(phrase: "Show context graph"),
                .init(phrase: "Show recent work sessions"),
                .init(phrase: "What was I doing earlier?", kind: .followUp),
            ],
            relatedSettings: ["Settings → Developer Mode → Runtime Diagnostics"],
            limitations: [
                "Focus is inferred from passive signals, not guaranteed to be correct.",
                "Context graph starts empty and improves as you work.",
                "Private/incognito app content is never included.",
            ],
            status: nodeCount > 0 ? .enabled : .notConfigured,
            searchTags: ["focus", "context", "graph", "working on", "project", "leave off",
                         "provenance", "explain", "confidence", "ranking"]
        )
    }
}
