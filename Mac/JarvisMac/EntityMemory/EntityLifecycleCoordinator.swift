import Foundation

// MARK: - EntityLifecycleCoordinator

@MainActor
final class EntityLifecycleCoordinator {

    static let shared = EntityLifecycleCoordinator()

    private let extractor = ConversationEntityExtractor.shared
    private let salience  = EntitySalienceEngine.shared

    private var busToken: SystemBus.SubscriptionToken?
    private var pruneTask: Task<Void, Never>?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); return f
    }()

    // MARK: - Start / Stop

    func start() {
        busToken = SystemBus.shared.subscribe(SpeechCommandReceivedEvent.self) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.ingestSpeechCommand(event)
            }
        }
        schedulePruneLoop()
    }

    func stop() {
        if let token = busToken { SystemBus.shared.unsubscribe(token) }
        busToken = nil
        pruneTask?.cancel()
        pruneTask = nil
    }

    // MARK: - Ingest sources

    func ingestSpeechCommand(_ event: SpeechCommandReceivedEvent) {
        let graph = EntityMemoryGraph.shared
        let nodes = extractor.extract(from: event.transcript, source: .conversation)
        for node in nodes { graph.upsert(node) }
        salience.recomputeAll()
    }

    func ingestPresence(_ snapshot: PresenceSnapshot) {
        let graph = EntityMemoryGraph.shared

        if let file = snapshot.activeCodingFile {
            var node = EntityMemNode(entityKind: .file, canonicalName: file,
                                  source: .windowsPresence)
            node.associatedDevices = [snapshot.deviceId]
            if let lang = snapshot.activeCodingLanguage { node.metadata["language"] = lang }
            graph.upsert(node)
        }

        if let url = snapshot.browserURL {
            var node = EntityMemNode(entityKind: .browserTab, canonicalName: url,
                                  source: .windowsPresence, expiryPolicy: .session)
            node.associatedUrls = [url]
            node.associatedDevices = [snapshot.deviceId]
            if let title = snapshot.foregroundWindowTitle { node.aliases = [title] }
            graph.upsert(node)
        }

        if let app = snapshot.foregroundApp {
            var node = EntityMemNode(entityKind: .window, canonicalName: app,
                                  source: .windowsPresence, expiryPolicy: .session)
            node.associatedDevices = [snapshot.deviceId]
            graph.upsert(node)
        }

        salience.recomputeAll(activeUrls: snapshot.browserURL.map { [$0] } ?? [])
    }

    func ingestCalendarEvent(title: String, startDate: Date, endDate: Date) {
        var node = EntityMemNode(entityKind: .calendarEvent, canonicalName: title,
                              source: .calendarEvent, expiryPolicy: .workflow)
        node.metadata["startDate"] = Self.isoFormatter.string(from: startDate)
        node.metadata["endDate"]   = Self.isoFormatter.string(from: endDate)
        EntityMemoryGraph.shared.upsert(node)
    }

    func ingestGitHubNotification(title: String, url: String, kind: EntityMemKind) {
        var node = EntityMemNode(entityKind: kind, canonicalName: title,
                              source: .githubAPI, expiryPolicy: .workflow)
        node.associatedUrls = [url]
        EntityMemoryGraph.shared.upsert(node)
    }

    func ingestTodoistTask(title: String, projectName: String?) {
        var node = EntityMemNode(entityKind: .task, canonicalName: title,
                              source: .todoistTask, expiryPolicy: .workflow)
        if let project = projectName { node.metadata["project"] = project }
        EntityMemoryGraph.shared.upsert(node)
    }

    func ingestProactiveEvent(_ event: ProactiveEvent) {
        guard let entity = event.relatedEntity, !entity.isEmpty else { return }
        let node = EntityMemNode(entityKind: .genericConcept, canonicalName: entity,
                              source: .proactiveEvent, expiryPolicy: .session)
        EntityMemoryGraph.shared.upsert(node)
    }

    // MARK: - Prune loop (every 30 min)

    private func schedulePruneLoop() {
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.salience.applyDecay()
                    EntityMemoryGraph.shared.prune()
                }
            }
        }
    }
}
