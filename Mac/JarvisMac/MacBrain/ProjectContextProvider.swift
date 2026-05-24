import Foundation

/// Returns the active project focus and today's episode summary.
@MainActor
final class ProjectContextProvider: BrainContextProviding {
    let category = "project"

    func provide(query: String?, maxItems: Int) async -> BrainContextBlock? {
        let focus = ProjectRelationshipIndex.shared.activeFocusContext()
        let todaySummary = EpisodeStore.shared.todaysSummary()

        var items: [BrainContextItem] = []

        if let project = focus.dominantProject, !project.isEmpty {
            items.append(BrainContextItem(
                key: "active_project",
                value: project,
                confidence: focus.confidence,
                source: "context_graph"
            ))
            items.append(BrainContextItem(
                key: "focus_reason",
                value: focus.reason,
                confidence: focus.confidence,
                source: "context_graph"
            ))
        }

        // Top-3 ranked context nodes as brief topics
        let topNodes = focus.rankedNodes.prefix(3)
        for node in topNodes {
            let label = node.node.title
            if !label.isEmpty, label != focus.dominantProject {
                items.append(BrainContextItem(
                    key: "context_node",
                    value: label,
                    confidence: node.total,
                    source: node.node.type.rawValue
                ))
            }
        }

        if !todaySummary.isEmpty {
            items.append(BrainContextItem(
                key: "today_episodes",
                value: todaySummary,
                confidence: nil,
                source: "episode_store"
            ))
        }

        guard !items.isEmpty else { return nil }
        return BrainContextBlock(category: category, label: "Project focus", items: items)
    }
}
