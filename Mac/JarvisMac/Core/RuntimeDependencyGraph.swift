import Foundation

// MARK: - RuntimeDependency

/// Explicit declaration of what each runtime depends on.
/// Used by RuntimeCoordinator for restart ordering and diagnostics.
struct RuntimeDependencyEntry {
    let id: String
    let dependsOn: [String]   // IDs of required runtimes
    let softDependsOn: [String]  // Degraded if missing, not failed
}

// MARK: - RuntimeDependencyGraph

/// The authoritative dependency map for all registered runtimes.
/// Consulted by RuntimeCoordinator when deciding restart order.
struct RuntimeDependencyGraph {

    static let shared = RuntimeDependencyGraph()

    let entries: [String: RuntimeDependencyEntry] = {
        let all: [RuntimeDependencyEntry] = [
            RuntimeDependencyEntry(
                id: "system",
                dependsOn: [],
                softDependsOn: []
            ),
            RuntimeDependencyEntry(
                id: "memory",
                dependsOn: ["system"],
                softDependsOn: []
            ),
            RuntimeDependencyEntry(
                id: "audio",
                dependsOn: ["system"],
                softDependsOn: []
            ),
            RuntimeDependencyEntry(
                id: "conversation",
                dependsOn: ["audio", "system"],
                softDependsOn: ["memory"]
            ),
            RuntimeDependencyEntry(
                id: "overlay",
                dependsOn: ["system"],
                softDependsOn: []
            ),
            RuntimeDependencyEntry(
                id: "ambient",
                dependsOn: ["system", "overlay"],
                softDependsOn: ["conversation"]
            ),
            RuntimeDependencyEntry(
                id: "llm",
                dependsOn: ["system", "memory"],
                softDependsOn: []
            ),
            RuntimeDependencyEntry(
                id: "proactivity",
                dependsOn: ["system", "overlay", "conversation"],
                softDependsOn: ["llm", "ambient"]
            ),
            RuntimeDependencyEntry(
                id: "android",
                dependsOn: ["system"],
                softDependsOn: ["conversation"]
            ),
            RuntimeDependencyEntry(
                id: "brain",
                dependsOn: ["memory"],
                softDependsOn: ["llm"]
            ),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    // MARK: - Queries

    func hardDependencies(of id: String) -> [String] {
        entries[id]?.dependsOn ?? []
    }

    func softDependencies(of id: String) -> [String] {
        entries[id]?.softDependsOn ?? []
    }

    /// All runtimes that must be restarted BEFORE `id` can restart.
    func restartPrerequisites(for id: String) -> [String] {
        guard let entry = entries[id] else { return [] }
        return entry.dependsOn
    }

    /// All runtimes that depend (hard or soft) on `id`.
    /// These become degraded if `id` fails.
    func dependents(of id: String) -> [String] {
        entries.values.filter { entry in
            entry.dependsOn.contains(id) || entry.softDependsOn.contains(id)
        }.map { $0.id }
    }

    /// Topological sort: runtimes ordered from fewest to most dependencies.
    /// Respects hard dependency ordering for startup sequencing.
    func topologicalOrder() -> [String] {
        var visited = Set<String>()
        var result: [String] = []

        func visit(_ id: String) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            for dep in hardDependencies(of: id) { visit(dep) }
            result.append(id)
        }

        for id in entries.keys.sorted() { visit(id) }
        return result
    }

    /// Whether removing `id` from the running set would cause `other` to fail hard.
    func isHardBlocked(_ other: String, by id: String) -> Bool {
        hardDependencies(of: other).contains(id)
    }
}
