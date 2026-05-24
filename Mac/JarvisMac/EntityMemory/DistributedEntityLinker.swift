import Foundation

// MARK: - DistributedEntityLinker

@MainActor
final class DistributedEntityLinker {

    static let shared = DistributedEntityLinker()

    private let lifecycle = EntityLifecycleCoordinator.shared

    // MARK: - Windows presence → entity graph

    func ingestPresence(_ snapshot: PresenceSnapshot) {
        lifecycle.ingestPresence(snapshot)
        if let title = snapshot.foregroundWindowTitle, let url = snapshot.browserURL {
            linkWindowTitleToEntities(title: title, url: url, deviceId: snapshot.deviceId)
        }
    }

    // MARK: - "On Windows" phrase resolution

    func resolveWithDeviceBias(phrase: String, deviceId: String) -> ResolutionResult {
        let graph = EntityMemoryGraph.shared
        let deviceNodes = graph.all().filter {
            $0.associatedDevices.contains(deviceId) && !$0.isExpired
        }.sorted { $0.relevanceScore() > $1.relevanceScore() }

        guard let best = deviceNodes.first else { return .empty }
        return ResolutionResult(
            entity: best,
            confidence: 0.75,
            source: "device_biased",
            candidates: Array(deviceNodes.prefix(3)),
            needsClarification: false,
            clarificationPrompt: nil
        )
    }

    // MARK: - Enrich existing entity with device association

    func enrichEntity(id: String, deviceId: String) {
        let graph = EntityMemoryGraph.shared
        guard var node = graph.node(id: id) else { return }
        guard !node.associatedDevices.contains(deviceId) else { return }
        node.associatedDevices.append(deviceId)
        graph.upsert(node)
    }

    // MARK: - Private

    private func linkWindowTitleToEntities(title: String, url: String, deviceId: String) {
        let graph = EntityMemoryGraph.shared
        let candidates = graph.byKind(.pullRequest, limit: 10) + graph.byKind(.githubIssue, limit: 10)
        for candidate in candidates {
            let lowerTitle = title.lowercased()
            let lowerName  = candidate.canonicalName.lowercased()
            if lowerTitle.contains(lowerName) || candidate.associatedUrls.contains(url) {
                enrichEntity(id: candidate.id, deviceId: deviceId)
            }
        }
    }
}
