import Foundation

/// Stores ALIAS_CORRECTION and HOME_ASSISTANT_CORRECTION events from Android.
/// These represent user-facing corrections (e.g. "you said X but I meant Y")
/// that can be used to improve entity resolution and phrase matching.
/// Bounded at 200 entries.
@MainActor
final class BrainCorrectionStore {

    static let maxEvents = 200

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
        return base.appendingPathComponent("brain_corrections.json")
    }
}
