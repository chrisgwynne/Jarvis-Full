import Foundation

/// Append-only store for generic Android interaction events (COMMAND_OUTCOME,
/// CONVERSATION_SUMMARY, and any unrecognised types).
/// Deduplicates by eventId. Bounded at 500 entries. JSON-persisted.
@MainActor
final class BrainInteractionStore {

    static let maxEvents = 500

    private let fileURL: URL
    private(set) var events: [BrainInteractionEvent] = []
    private var seenIds: Set<String> = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    func save(_ event: BrainInteractionEvent) async throws {
        guard !seenIds.contains(event.eventId) else { return }
        seenIds.insert(event.eventId)
        events.append(event)
        if events.count > Self.maxEvents {
            let excess = events.count - Self.maxEvents
            let removed = events.prefix(excess)
            for e in removed { seenIds.remove(e.eventId) }
            events.removeFirst(excess)
        }
        persist()
    }

    var count: Int { events.count }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BrainInteractionEvent].self, from: data)
        else { return }
        events = decoded
        seenIds = Set(decoded.map(\.eventId))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("brain_interactions.json")
    }
}
