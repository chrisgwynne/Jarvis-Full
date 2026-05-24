import Foundation

/// Query and ingestion layer over `ContextGraph`.
///
/// This is the public API for the context graph system.  Callers inject source
/// closures once (in bootstrap) and then call `refresh()` to populate the graph.
/// All methods are read-only after ingestion — the graph is never mutated by
/// queries.
@MainActor final class ProjectRelationshipIndex {

    static let shared = ProjectRelationshipIndex()

    private let graph       = ContextGraph.shared
    private let persistence = ContextGraphPersistence()
    private let focusState  = ProjectFocusState()
    private var lastPruneResult: PruneResult?

    // Reentrancy guard — prevents nested/concurrent refresh calls.
    private var isRefreshing = false
    // Safe-mode flag — set when node count approaches cap; disables heavy ingestion.
    private(set) var graphSafeMode = false
    // Counts how many refresh() calls were short-circuited by safe mode.
    private(set) var safeModeSkipCount = 0

    // MARK: - Ingestion caps (tuned to prevent O(N²) growth)
    private static let maxMemoriesPerRefresh    = 80
    private static let maxTracesPerRefresh      = 10
    private static let maxCrossLinksPerThread   = 8
    private static let safeModeNodeThreshold    = 500   // 83% of 600 cap → engage safe mode

    // MARK: - Injected source closures (wired by JarvisController bootstrap)

    var getTaskThreads:           () -> [TaskThread]              = { [] }
    var getMemories:              () -> [MemoryCandidate]         = { [] }
    var getObsidianNotes:         () -> [ObsidianNote]            = { [:].values.map { $0 } }
    var getTraces:                () -> [ExecutionTrace]          = { [] }
    var getGitHubNotifications:   () -> [GHNotification]          = { [] }
    var getTodoistTasks:          () -> [TodoistAPIClient.Task]   = { [] }

    private(set) var lastIngestionAt: Date? { get { graph.lastIngestionAt } set { } }

    // MARK: - Persistence

    /// Loads a previously-saved graph from disk before the first refresh().
    /// Runs an immediate prune so accumulated stale nodes from prior sessions
    /// don't push the graph over the cap before new ingestion runs.
    func loadFromDisk() {
        persistence.load(into: graph)
    }

    // MARK: - Ingestion

    /// Re-ingests all wired sources into the graph, then prunes and schedules a save.
    ///
    /// Reentrancy-safe: concurrent calls are silently dropped.
    /// Safe-mode: if node count is near the cap, skips heavy ingestion and only
    /// runs prune + save, keeping Jarvis running without adding more pressure.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let refreshStart = Date()

        // Safe-mode check — if graph is near capacity, only prune and bail.
        if graph.nodeCount >= Self.safeModeNodeThreshold {
            graphSafeMode = true
            safeModeSkipCount += 1
            lastPruneResult = graph.prune()
            updateFocusState()
            graph.markIngested()
            persistence.scheduleSave(graph: graph)
            return
        }
        graphSafeMode = false

        // Execution traces are ephemeral — clear stale ones before re-ingesting
        // so nodes from previous sessions don't persist across restarts.
        let staleTraceIDs = graph.nodes(ofType: .executionTrace).map(\.id)
        staleTraceIDs.forEach { graph.removeNode(id: $0) }

        ingestTaskThreads(getTaskThreads())
        ingestMemories(Array(getMemories().prefix(Self.maxMemoriesPerRefresh)))
        ingestObsidianNotes(Array(getObsidianNotes()))
        ingestExecutionTraces(Array(getTraces().prefix(Self.maxTracesPerRefresh)))
        ingestGitHubNotifications(getGitHubNotifications())
        ingestTodoistTasks(getTodoistTasks())
        enrichCrossLinks()
        lastPruneResult = graph.prune()
        updateFocusState()
        graph.markIngested()

        let duration = Date().timeIntervalSince(refreshStart)
        lastRefreshDuration = duration

        persistence.scheduleSave(graph: graph)
    }

    private(set) var lastRefreshDuration: TimeInterval = 0

    // MARK: - Ingestion: Task Threads

    func ingestTaskThreads(_ threads: [TaskThread]) {
        guard !threads.isEmpty else { return }
        for thread in threads {
            let nodeID = graph.upsertNode(ContextNode(
                type:       .taskThread,
                title:      thread.title,
                summary:    thread.summary,
                source:     .taskThread,
                confidence: thread.confidence,
                trustTier:  .system,
                metadata:   [
                    "apps":     thread.apps.prefix(3).joined(separator: ", "),
                    "duration": "\(Int(thread.durationSeconds))s",
                    "isActive": thread.isActive ? "true" : "false",
                ],
                externalID: thread.id.uuidString
            ))

            // Each app mentioned in the thread becomes an activeApp node linked to the thread
            for app in thread.apps.prefix(3) {
                let appNode = ContextNode(
                    type:       .activeApp,
                    title:      app,
                    summary:    "App used during task thread",
                    source:     .ambientContext,
                    confidence: 0.9,
                    trustTier:  .system,
                    externalID: "app:\(app.lowercased())"
                )
                let appID = graph.upsertNode(appNode)
                graph.upsertEdge(ContextEdge(
                    from:     nodeID,
                    to:       appID,
                    type:     .recentlyUsedWith,
                    evidence: "app open during thread '\(thread.title)'"
                ))
            }

            // Infer a project node if the thread title suggests one
            if let projectName = inferProjectName(from: thread.title, entities: thread.entities) {
                let projNode = ContextNode(
                    type:       .project,
                    title:      projectName,
                    summary:    "Project inferred from task thread",
                    source:     .system,
                    confidence: 0.6,
                    trustTier:  .inferred,
                    externalID: "project:\(projectName.lowercased())"
                )
                let projID = graph.upsertNode(projNode)
                graph.upsertEdge(ContextEdge(
                    from:     nodeID,
                    to:       projID,
                    type:     .belongsToProject,
                    evidence: "thread title '\(thread.title)' suggests project"
                ))
            }
        }
    }

    // MARK: - Ingestion: Memories

    func ingestMemories(_ candidates: [MemoryCandidate]) {
        guard !candidates.isEmpty else { return }
        for m in candidates {
            guard m.type != .discard else { continue }
            let trustTier: TrustTier = m.isPinned ? .userEdited : .system
            let nodeID = graph.upsertNode(ContextNode(
                type:       .memory,
                title:      m.title,
                summary:    m.summary,
                source:     .conversationMemory,
                confidence: m.confidence,
                trustTier:  trustTier,
                metadata:   ["memType": m.type.rawValue,
                             "isPinned": m.isPinned ? "true" : "false"],
                externalID: m.id.uuidString
            ))

            // Link memories sharing tags
            for tag in m.tags.prefix(3) {
                let tagKey = "tag:\(tag.lowercased())"
                if let existing = graph.findByExternalID(tagKey, type: .project) {
                    graph.upsertEdge(ContextEdge(
                        from:     nodeID,
                        to:       existing.id,
                        type:     .sameTopicAs,
                        evidence: "shared tag '\(tag)'"
                    ))
                } else {
                    let projNode = ContextNode(
                        type:       .project,
                        title:      tag.capitalized,
                        summary:    "Topic derived from memory tags",
                        source:     .conversationMemory,
                        confidence: 0.5,
                        trustTier:  .inferred,
                        externalID: tagKey
                    )
                    let projID = graph.upsertNode(projNode)
                    graph.upsertEdge(ContextEdge(
                        from:     nodeID,
                        to:       projID,
                        type:     .sameTopicAs,
                        evidence: "memory tagged '\(tag)'"
                    ))
                }
            }
        }
    }

    // MARK: - Ingestion: Obsidian Notes

    func ingestObsidianNotes(_ notes: [ObsidianNote]) {
        guard !notes.isEmpty else { return }
        for note in notes.prefix(100) {   // cap: avoid ingesting huge vaults in one pass
            let nodeID = graph.upsertNode(ContextNode(
                type:       .obsidianNote,
                title:      note.title,
                summary:    note.snippet,
                source:     .obsidianVault,
                confidence: 0.85,
                trustTier:  .synced,
                metadata:   ["tags": note.tags.prefix(5).joined(separator: ", "),
                             "wikilinks": note.wikilinks.prefix(3).joined(separator: ", ")],
                externalID: "obsidian:\(note.id)"
            ))

            // Wikilinks create references to other notes
            for link in note.wikilinks.prefix(5) {
                let targetKey = "obsidian:\(link)"
                if let target = graph.findByExternalID(targetKey, type: .obsidianNote) {
                    graph.upsertEdge(ContextEdge(
                        from:     nodeID,
                        to:       target.id,
                        type:     .references,
                        evidence: "[[wikilink]] in '\(note.title)'"
                    ))
                }
            }

            // Tags become project/topic nodes
            for tag in note.tags.prefix(3) {
                let tagKey = "tag:\(tag.lowercased())"
                let tagNodeID: UUID
                if let existing = graph.findByExternalID(tagKey, type: .project) {
                    tagNodeID = existing.id
                } else {
                    tagNodeID = graph.upsertNode(ContextNode(
                        type:       .project,
                        title:      tag.capitalized,
                        summary:    "Topic from Obsidian tag",
                        source:     .obsidianVault,
                        confidence: 0.7,
                        trustTier:  .inferred,
                        externalID: tagKey
                    ))
                }
                graph.upsertEdge(ContextEdge(
                    from:     nodeID,
                    to:       tagNodeID,
                    type:     .belongsToProject,
                    evidence: "note '\(note.title)' tagged '#\(tag)'"
                ))
            }
        }
    }

    // MARK: - Ingestion: Execution Traces

    func ingestExecutionTraces(_ traces: [ExecutionTrace]) {
        guard !traces.isEmpty else { return }
        for (i, trace) in traces.enumerated() {
            let nodeID = graph.upsertNode(ContextNode(
                type:       .executionTrace,
                title:      trace.label,
                summary:    trace.steps.map(\.name).joined(separator: " → "),
                source:     .executionTrace,
                confidence: trace.isComplete ? 0.95 : 0.6,
                trustTier:  .system,
                metadata:   ["steps": "\(trace.steps.count)",
                             "durationMs": "\(trace.durationMs)",
                             "complete": trace.isComplete ? "true" : "false"],
                externalID: trace.correlationID.uuidString
            ))

            // Link consecutive traces together
            if i + 1 < traces.count {
                let nextTrace = traces[i + 1]
                if let nextID = graph.findByExternalID(nextTrace.correlationID.uuidString,
                                                       type: .executionTrace)?.id {
                    graph.upsertEdge(ContextEdge(
                        from:     nodeID,
                        to:       nextID,
                        type:     .followedBy,
                        evidence: "consecutive execution traces"
                    ))
                }
            }
        }
    }

    // MARK: - Ingestion: GitHub Notifications

    func ingestGitHubNotifications(_ notifications: [GHNotification]) {
        guard !notifications.isEmpty else { return }
        for note in notifications {
            let nodeID = graph.upsertNode(ContextNode(
                type:       .githubIssue,
                title:      note.subject.title,
                summary:    "\(note.reason) · \(note.repository.full_name)",
                source:     .githubIssue,
                confidence: note.unread ? 0.85 : 0.60,
                trustTier:  .system,
                metadata:   ["repo":   note.repository.full_name,
                             "reason": note.reason,
                             "type":   note.subject.type],
                externalID: "gh:\(note.id)"
            ))

            // Link to a project node derived from the repo name
            let repoParts  = note.repository.full_name.components(separatedBy: "/")
            let repoSlug   = repoParts.last ?? note.repository.full_name
            let repoKey    = "project:\(repoSlug.lowercased())"
            let projID: UUID
            if let existing = graph.findByExternalID(repoKey, type: .project) {
                projID = existing.id
            } else {
                projID = graph.upsertNode(ContextNode(
                    type:       .project,
                    title:      repoSlug,
                    summary:    "GitHub repo \(note.repository.full_name)",
                    source:     .githubRepo,
                    confidence: 0.70,
                    trustTier:  .inferred,
                    externalID: repoKey
                ))
            }
            graph.upsertEdge(ContextEdge(
                from:     nodeID,
                to:       projID,
                type:     .belongsToProject,
                evidence: "GitHub notification in repo '\(note.repository.full_name)'"
            ))
        }
    }

    // MARK: - Ingestion: Todoist Tasks

    func ingestTodoistTasks(_ tasks: [TodoistAPIClient.Task]) {
        guard !tasks.isEmpty else { return }
        for task in tasks where !task.is_completed {
            let due    = task.due?.string ?? "no due date"
            let nodeID = graph.upsertNode(ContextNode(
                type:       .todoistTask,
                title:      task.content,
                summary:    task.description.isEmpty ? due : "\(task.description) · \(due)",
                source:     .todoistTask,
                confidence: task.priority >= 3 ? 0.80 : 0.60,
                trustTier:  .synced,
                metadata:   ["priority": "\(task.priority)", "due": due],
                externalID: "todoist:\(task.id)"
            ))

            // Infer project from first multi-word capitalised entity in task content
            if let projectName = inferProjectName(from: task.content, entities: []) {
                let projKey = "project:\(projectName.lowercased())"
                let projID: UUID
                if let existing = graph.findByExternalID(projKey, type: .project) {
                    projID = existing.id
                } else {
                    projID = graph.upsertNode(ContextNode(
                        type:       .project,
                        title:      projectName,
                        summary:    "Project inferred from Todoist task",
                        source:     .todoistTask,
                        confidence: 0.50,
                        trustTier:  .inferred,
                        externalID: projKey
                    ))
                }
                graph.upsertEdge(ContextEdge(
                    from:     nodeID,
                    to:       projID,
                    type:     .belongsToProject,
                    evidence: "Todoist task '\(task.content)' suggests project"
                ))
            }
        }
    }

    // MARK: - Cross-link Enrichment

    /// Creates `sameTopicAs` edges between task threads and memories that share
    /// a significant keyword (≥5 chars, present in both titles).
    ///
    /// Capped at `maxCrossLinksPerThread` per thread to prevent O(N²) edge growth.
    private func enrichCrossLinks() {
        let threads  = graph.nodes(ofType: .taskThread)
        let memories = graph.nodes(ofType: .memory)
        guard !threads.isEmpty, !memories.isEmpty else { return }

        for thread in threads {
            let threadWords = significantWords(in: thread.title)
            guard !threadWords.isEmpty else { continue }
            var created = 0
            for memory in memories {
                guard created < Self.maxCrossLinksPerThread else { break }
                let memWords = significantWords(in: memory.title + " " + memory.summary)
                guard !threadWords.isDisjoint(with: memWords) else { continue }
                graph.upsertEdge(ContextEdge(
                    from:       thread.id,
                    to:         memory.id,
                    type:       .sameTopicAs,
                    confidence: 0.55,
                    evidence:   "shared keywords"
                ))
                created += 1
            }
        }
    }

    private func significantWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 5 }
        )
    }

    // MARK: - Focus State Update (called from refresh)

    /// Derives a project-score vector from the current graph and feeds it to
    /// `ProjectFocusState` for hysteresis-smoothed focus tracking.
    private func updateFocusState() {
        let now = Date()
        let projects = graph.nodes(ofType: .project)
        guard !projects.isEmpty else { return }

        let candidates: [(project: String, score: Double)] = projects.map { proj in
            let incoming = graph.incomingEdges(to: proj.id)
                .compactMap { graph.node(for: $0.from) }
            guard !incoming.isEmpty else {
                return (proj.title, proj.confidence * 0.4)
            }
            let weightedSum = incoming.reduce(0.0) { acc, node in
                let ageHours = now.timeIntervalSince(node.updatedAt) / 3600
                let recency  = max(0, 1 - ageHours / 48)
                let trust    = ContextRanking.trustScore(node.trustTier)
                return acc + node.confidence * recency * trust
            }
            return (proj.title, min(weightedSum / Double(incoming.count), 1.0))
        }

        focusState.update(candidates: candidates)
    }

    // MARK: - Focus Context (ranked query)

    /// Returns a ranked view of the current context for LLM injection.
    ///
    /// Uses `ProjectFocusState` (hysteresis-stabilised) as the anchor and
    /// `ContextRanking` to score all non-noise candidate nodes.
    func activeFocusContext() -> FocusContext {
        let now = Date()

        // Active apps from the most-recently-updated task thread
        let activeThread = graph.nodes(ofType: .taskThread)
            .filter { $0.metadata["isActive"] == "true" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first

        let activeApps: Set<String>
        if let appsStr = activeThread?.metadata["apps"], !appsStr.isEmpty {
            activeApps = Set(appsStr.components(separatedBy: ", ").map { $0.lowercased() })
        } else {
            activeApps = []
        }

        // Focus keywords from current stable project
        let focusKeywords: Set<String>
        if let project = focusState.currentFocus {
            focusKeywords = ContextRanking.significantWords(in: project)
        } else {
            focusKeywords = []
        }

        let ctx = RankingContext(
            activeApps:    activeApps,
            focusKeywords: focusKeywords,
            now:           now
        )

        // Rank all non-noise nodes
        let candidates = graph.nodesByID.values.filter {
            $0.type != .executionTrace && $0.type != .activeApp
        }
        let ranked = ContextRanking.rank(
            nodes:     Array(candidates),
            relativeTo: graph,
            context:   ctx
        )

        let reason = focusState.currentFocus
            .map { focusState.whyFocused(project: $0) }
            ?? "no dominant project detected"

        return FocusContext(
            dominantProject: focusState.currentFocus,
            confidence:      focusState.currentConfidence,
            rankedNodes:     Array(ranked.prefix(10)),
            reason:          reason
        )
    }

    // MARK: - Query API

    /// Returns nodes directly connected (in or out) to the given node.
    func related(to nodeID: UUID, limit: Int = 10) -> [ContextNode] {
        Array(graph.neighbours(of: nodeID).prefix(limit))
    }

    /// Returns the most recently updated nodes across all types.
    func recentProjectContext(limit: Int = 8) -> [ContextNode] {
        Array(
            graph.nodesByID.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    /// Returns all nodes whose title, summary, or metadata contains the project name.
    func contextForProject(name: String, limit: Int = 10) -> [ContextNode] {
        let lower = name.lowercased()
        let matches = graph.nodesByID.values.filter { node in
            node.title.lowercased().contains(lower)
            || node.summary.lowercased().contains(lower)
            || node.metadata.values.contains { $0.lowercased().contains(lower) }
        }
        return Array(matches.sorted { $0.confidence > $1.confidence }.prefix(limit))
    }

    /// Returns the active project's continuity chain:
    /// active task thread → linked memories → linked project nodes.
    ///
    /// Prefers actively-flagged threads; falls back to most-recently-updated
    /// thread if none are flagged active.
    func activeContinuityChain(limit: Int = 5) -> [ContextNode] {
        let allThreads = graph.nodes(ofType: .taskThread)
            .sorted { $0.updatedAt > $1.updatedAt }
        let anchor = allThreads.first(where: { $0.metadata["isActive"] == "true" })
                  ?? allThreads.first
        guard let anchor else { return [] }

        var chain   = [anchor]
        var visited = Set([anchor.id])

        // BFS up to `limit` hops, preferring memory and project nodes
        var frontier = [anchor.id]
        while chain.count < limit, !frontier.isEmpty {
            let nextFrontier = frontier.flatMap { graph.outgoingEdges(from: $0) }
                .sorted { $0.confidence > $1.confidence }
                .compactMap { graph.node(for: $0.to) }
                .filter { !visited.contains($0.id) }
            for node in nextFrontier {
                guard chain.count < limit else { break }
                chain.append(node)
                visited.insert(node.id)
                frontier.append(node.id)
            }
            if nextFrontier.isEmpty { break }
        }
        return chain
    }

    /// Explains why a particular node was selected and what connects it to context.
    func explainProvenance(for nodeID: UUID, charBudget: Int = 2000) -> ContextProvenance {
        guard let anchor = graph.node(for: nodeID) else {
            return ContextProvenance(
                nodeID: nodeID, nodeTitle: "Unknown",
                entries: [], totalCharBudget: charBudget,
                usedCharBudget: 0, truncatedSources: [],
                excludedSources: [], generatedAt: Date()
            )
        }

        var entries  = [ProvenanceEntry]()
        var usedChars = 0
        var truncated = [String]()
        var excluded  = [String]()

        // Include the anchor node itself
        let anchorChars = min(anchor.summary.count + anchor.title.count, charBudget - usedChars)
        if anchorChars > 0 {
            entries.append(ProvenanceEntry(
                source:    anchor.source,
                nodeType:  anchor.type,
                nodeID:    anchor.id,
                nodeTitle: anchor.title,
                trustTier: anchor.trustTier,
                charCount: anchorChars,
                reason:    "anchor node"
            ))
            usedChars += anchorChars
        }

        // Walk one hop out
        let edges = graph.outgoingEdges(from: nodeID)
            .sorted { $0.confidence > $1.confidence }
        for edge in edges {
            guard let neighbour = graph.node(for: edge.to) else { continue }
            let available = charBudget - usedChars
            if available <= 0 {
                truncated.append(neighbour.title)
                continue
            }
            let chars = min(neighbour.summary.count + neighbour.title.count, available)
            entries.append(ProvenanceEntry(
                source:    neighbour.source,
                nodeType:  neighbour.type,
                nodeID:    neighbour.id,
                nodeTitle: neighbour.title,
                trustTier: neighbour.trustTier,
                charCount: chars,
                reason:    edge.type.displayName
            ))
            usedChars += chars
        }

        // Collect incoming nodes that were excluded due to budget
        let allNeighbourIDs = Set(edges.map(\.to))
        let inEdges = graph.incomingEdges(to: nodeID)
        for edge in inEdges {
            guard !allNeighbourIDs.contains(edge.from) else { continue }
            if let n = graph.node(for: edge.from) {
                excluded.append(n.title)
            }
        }

        return ContextProvenance(
            nodeID:            nodeID,
            nodeTitle:         anchor.title,
            entries:           entries,
            totalCharBudget:   charBudget,
            usedCharBudget:    usedChars,
            truncatedSources:  truncated,
            excludedSources:   excluded,
            generatedAt:       Date()
        )
    }

    // MARK: - Diagnostics

    // 5-second cache to avoid running ContextRanking.rank() on every overlay tick.
    private var cachedDiagnostics: ContextGraphDiagnostics?
    private var diagnosticsCachedAt: Date = .distantPast

    var diagnostics: ContextGraphDiagnostics {
        if let cached = cachedDiagnostics,
           Date().timeIntervalSince(diagnosticsCachedAt) < 5 {
            return cached
        }
        let fresh = buildDiagnostics()
        cachedDiagnostics = fresh
        diagnosticsCachedAt = Date()
        return fresh
    }

    private func buildDiagnostics() -> ContextGraphDiagnostics {
        let typeHist = Dictionary(grouping: graph.nodesByID.values, by: \.type)
            .mapValues(\.count)
        let edgeHist = Dictionary(grouping: graph.edgesByID.values, by: \.type)
            .mapValues(\.count)

        let focusCtx = activeFocusContext()
        let chain    = activeContinuityChain()

        // Prefer hysteresis-stable focus project; fall back to chain / recency
        let project = focusCtx.dominantProject
            ?? chain.first(where: { $0.type == .project })?.title
            ?? graph.nodes(ofType: .project)
                .sorted { $0.updatedAt > $1.updatedAt }
                .first?.title

        let budgetBySource = Dictionary(grouping: graph.nodesByID.values, by: { $0.source.displayName })
            .mapValues { nodes in nodes.reduce(0) { $0 + $1.summary.count + $1.title.count } }

        let candidateCount = graph.nodesByID.values.filter {
            $0.type != .executionTrace && $0.type != .activeApp
        }.count

        return ContextGraphDiagnostics(
            nodeCount:                   graph.nodeCount,
            edgeCount:                   graph.edgeCount,
            nodesByType:                 typeHist,
            edgesByType:                 edgeHist,
            lastIngestionAt:             graph.lastIngestionAt,
            topActiveProject:            project,
            activeContinuityChainLength: chain.count,
            contextBudgetBySource:       budgetBySource,
            excludedContextCount:        0,
            generatedAt:                 Date(),
            persistedGraphLoaded:        persistence.persistedGraphLoaded,
            lastSaveTime:                persistence.lastSaveTime,
            lastPruneResult:             lastPruneResult,
            nodeCap:                     ContextGraphPersistence.defaultNodeCap,
            edgeCap:                     ContextGraphPersistence.defaultEdgeCap,
            focusConfidence:             focusCtx.confidence,
            previousFocusProject:        focusState.previousFocus,
            rankedNodeCount:             focusCtx.rankedNodes.count,
            suppressedNodeCount:         max(0, candidateCount - focusCtx.rankedNodes.count),
            graphSafeMode:               graphSafeMode,
            lastRefreshDuration:         lastRefreshDuration,
            safeModeSkipCount:           safeModeSkipCount
        )
    }

    // MARK: - Private helpers

    private func inferProjectName(from title: String, entities: [String]) -> String? {
        // Heuristic: if the thread title contains a known repo-name pattern (word/word)
        // or a capitalised multi-word phrase, treat it as a project name.
        let parts = title.components(separatedBy: .whitespaces)
            .filter { $0.count > 3 && $0.first?.isUppercase == true }
        if parts.count >= 2 { return parts.prefix(2).joined(separator: " ") }
        // Look for "repo/path" pattern in entities
        for entity in entities {
            if entity.contains("/") && !entity.hasPrefix("http") {
                return entity.components(separatedBy: "/").last
            }
        }
        return nil
    }
}
