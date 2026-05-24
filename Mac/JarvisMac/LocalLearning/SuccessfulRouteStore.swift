import Foundation

struct SuccessfulRoute: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let normalizedTranscript: String
    let intent: String
    let target: String?
    let routingSource: InteractionSource
    var hitCount: Int
    var lastHitAt: Date
    var confidenceAvg: Double
}

@MainActor
final class SuccessfulRouteStore {
    private(set) var routes: [SuccessfulRoute] = []
    private let maxRoutes = 300
    private static let fileName = "ll_successful_routes.json"

    init() { load() }

    func record(transcript: String, intent: String, target: String?,
                source: InteractionSource, confidence: Double) {
        let norm = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = routes.firstIndex(where: { $0.normalizedTranscript == norm && $0.intent == intent }) {
            let prev = routes[i]
            routes[i].hitCount += 1
            routes[i].lastHitAt = Date()
            routes[i].confidenceAvg = (prev.confidenceAvg * Double(prev.hitCount) + confidence) / Double(prev.hitCount + 1)
            persist(); return
        }
        let r = SuccessfulRoute(
            id: UUID(), timestamp: Date(), normalizedTranscript: norm,
            intent: intent, target: target, routingSource: source,
            hitCount: 1, lastHitAt: Date(), confidenceAvg: confidence
        )
        routes.insert(r, at: 0)
        if routes.count > maxRoutes { routes.removeLast() }
        persist()
    }

    func match(normalizedTranscript: String) -> SuccessfulRoute? {
        let norm = normalizedTranscript.lowercased().trimmingCharacters(in: .whitespaces)
        return routes
            .filter { $0.hitCount >= 2 }
            .first { $0.normalizedTranscript == norm }
    }

    func top(limit: Int) -> [SuccessfulRoute] {
        routes.sorted { $0.hitCount > $1.hitCount }.prefix(limit).map { $0 }
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JarvisMac/\(fileName)")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([SuccessfulRoute].self, from: data)
        else { return }
        routes = decoded
    }
}
