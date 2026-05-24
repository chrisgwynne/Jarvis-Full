import Foundation

/// Stores MEMORY_CANDIDATE events from Android and opportunistically promotes
/// high-confidence candidates into BrainMemoryStore.
/// Bounded at 100 entries (memory candidates are larger payloads).
@MainActor
final class BrainMemoryCandidateStore {

    static let maxEvents = 100
    /// Minimum confidence for auto-promotion to BrainMemoryStore.
    static let promotionThreshold: Double = 0.65

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

        // Attempt promotion if confidence payload is present and high enough
        if let confStr = event.payload["confidence"],
           let conf = Double(confStr),
           conf >= Self.promotionThreshold,
           let title = event.payload["title"],
           let summary = event.payload["summary"] ?? event.payload["content"] {
            let candidate = MemoryCandidate(
                type: .idea,
                tier: .projectMemory,
                title: title,
                summary: summary,
                rawText: event.payload["raw_text"] ?? summary,
                confidence: conf,
                importance: Double(event.payload["importance"] ?? "0.5") ?? 0.5,
                tags: (event.payload["tags"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
                createdAt: Date(),
                source: .voiceCommand
            )
            await BrainMemoryStore.shared.commit(candidate)
        }
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
        return base.appendingPathComponent("brain_memory_candidates.json")
    }
}
