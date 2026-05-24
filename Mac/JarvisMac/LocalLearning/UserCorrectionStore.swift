import Foundation

struct UserCorrection: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let originalTranscript: String
    let originalIntent: String?
    let correctedPhrase: String?
    let correctedIntentHint: String
    let target: String?
    var applied: Bool
    var learnedAliasID: UUID?
}

@MainActor
final class UserCorrectionStore {
    private(set) var corrections: [UserCorrection] = []
    private let maxCorrections = 200
    private static let fileName = "ll_corrections.json"

    init() { load() }

    func record(_ correction: UserCorrection) {
        corrections.insert(correction, at: 0)
        if corrections.count > maxCorrections { corrections.removeLast() }
        persist()
    }

    func markApplied(id: UUID, aliasID: UUID? = nil) {
        guard let i = corrections.firstIndex(where: { $0.id == id }) else { return }
        corrections[i].applied = true
        corrections[i].learnedAliasID = aliasID
        persist()
    }

    func recent(limit: Int) -> [UserCorrection] { Array(corrections.prefix(limit)) }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JarvisMac/\(fileName)")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([UserCorrection].self, from: data)
        else { return }
        corrections = decoded
    }
}
