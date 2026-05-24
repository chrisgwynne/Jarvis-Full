import Foundation

// MARK: - EntitySalienceEngine

@MainActor
final class EntitySalienceEngine {

    static let shared = EntitySalienceEngine()

    // MARK: - Recompute all salience scores

    func recomputeAll(activeApp: String? = nil, activeUrls: [String] = []) {
        let graph = EntityMemoryGraph.shared
        for node in graph.all() {
            let s = computeSalience(node: node, activeApp: activeApp, activeUrls: activeUrls)
            graph.updateSalience(id: node.id, salience: s)
        }
    }

    // MARK: - Boost on explicit reference

    func boost(id: String) {
        let graph = EntityMemoryGraph.shared
        guard let node = graph.node(id: id) else { return }
        graph.markReferenced(id: id)
        graph.updateSalience(id: id, salience: min(node.salience + 0.15, 1.0))
    }

    // MARK: - Decay pass (call periodically)

    func applyDecay() {
        let graph = EntityMemoryGraph.shared
        let now = Date()
        for node in graph.all() {
            let age = now.timeIntervalSince(node.lastMentionedAt)
            let decayed = node.salience * pow(0.5, age / node.entityKind.halfLifeSeconds)
            graph.updateSalience(id: node.id, salience: max(decayed, 0.0))
        }
    }

    // MARK: - Private scoring

    private func computeSalience(node: EntityMemNode, activeApp: String?, activeUrls: [String]) -> Double {
        var score = 0.0
        score += node.currentRecencyScore() * 0.40
        score += min(Double(node.mentionCount) / 10.0, 1.0) * 0.20
        if let app = activeApp, node.associatedApps.contains(app) { score += 0.20 }
        for url in activeUrls where node.associatedUrls.contains(url) { score += 0.10; break }
        score += sourceTrust(node.source) * 0.10
        return min(score, 1.0)
    }

    private func sourceTrust(_ source: EntitySource) -> Double {
        switch source {
        case .userExplicit:      return 1.0
        case .conversation:      return 0.85
        case .githubAPI:         return 0.80
        case .calendarEvent:     return 0.80
        case .todoistTask:       return 0.75
        case .homeAssistant:     return 0.75
        case .windowsPresence:   return 0.70
        case .macPresence:       return 0.70
        case .proactiveEvent:    return 0.60
        case .ocrExtraction:     return 0.55
        case .workflowInference: return 0.50
        }
    }
}
