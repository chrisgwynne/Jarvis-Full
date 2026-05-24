import Foundation

// MARK: - EntityContextBlockBuilder

@MainActor
enum EntityContextBlockBuilder {

    private static let maxEntities     = 8
    private static let maxCharsPerName = 60
    private static let minSalience     = 0.20

    // MARK: - Main LLM context block

    static func build(query: String? = nil) -> String? {
        let top = EntityMemoryGraph.shared.topSalient(limit: maxEntities)
            .filter { $0.salience >= minSalience }
        guard !top.isEmpty else { return nil }

        var lines = ["[ENTITY MEMORY]"]
        lines.append("# \(top.count) known entities (top by salience)")

        for node in top {
            var desc = "\(node.entityKind.rawValue): \(String(node.canonicalName.prefix(maxCharsPerName)))"
            if let url = node.associatedUrls.first {
                desc += " (\(url.prefix(80)))"
            }
            desc += " [s=\(String(format: "%.2f", node.salience)), r=\(String(format: "%.2f", node.currentRecencyScore()))]"
            lines.append(desc)
        }

        if let workflow = WorkflowContextResolver.workflowContextBlock() {
            lines.append("")
            lines.append(workflow)
        }

        lines.append("# Use these to resolve vague references: 'it', 'that', 'the other one'.")
        return lines.joined(separator: "\n")
    }

    // MARK: - One-liner for disambiguation

    static func buildReferenceLine(for entity: EntityMemNode) -> String {
        var parts = ["\(entity.entityKind.rawValue): \(entity.canonicalName)"]
        if let url = entity.associatedUrls.first { parts.append("url=\(url.prefix(80))") }
        if let dev = entity.associatedDevices.first { parts.append("device=\(dev)") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Resolution explanation

    static func explain(result: ResolutionResult) -> String {
        guard let entity = result.entity else { return "no entity resolved" }
        return "resolved '\(entity.canonicalName)' via \(result.source) (\(Int(result.confidence * 100))%)"
    }
}
