import Foundation

struct FailedUtterance: Codable, Identifiable {
    let id: UUID
    let transcript: String
    let normalizedTranscript: String
    let timestamp: Date
    let detectedIntent: String?
    var attemptCount: Int
    var lastAttemptAt: Date
    var resolved: Bool
}

@MainActor
final class FailedUtteranceStore {
    private(set) var failures: [FailedUtterance] = []
    private let maxFailures = 200
    private static let fileName = "ll_failures.json"

    init() { load() }

    func record(transcript: String, detectedIntent: String?) {
        let norm = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = failures.firstIndex(where: { $0.normalizedTranscript == norm }) {
            failures[i].attemptCount += 1
            failures[i].lastAttemptAt = Date()
            persist(); return
        }
        let f = FailedUtterance(
            id: UUID(), transcript: transcript, normalizedTranscript: norm,
            timestamp: Date(), detectedIntent: detectedIntent,
            attemptCount: 1, lastAttemptAt: Date(), resolved: false
        )
        failures.insert(f, at: 0)
        if failures.count > maxFailures { failures.removeLast() }
        persist()
    }

    func markResolved(id: UUID) {
        guard let i = failures.firstIndex(where: { $0.id == id }) else { return }
        failures[i].resolved = true; persist()
    }

    func clear() { failures.removeAll(); persist() }

    func top(limit: Int) -> [FailedUtterance] {
        failures
            .filter { !$0.resolved }
            .sorted { $0.attemptCount > $1.attemptCount }
            .prefix(limit).map { $0 }
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JarvisMac/\(fileName)")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(failures) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([FailedUtterance].self, from: data)
        else { return }
        failures = decoded
    }
}
