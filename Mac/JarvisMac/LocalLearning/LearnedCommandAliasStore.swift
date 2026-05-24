import Foundation

struct LearnedAlias: Codable, Identifiable {
    let id: UUID
    var phrase: String
    var normalizedPhrase: String
    var intent: String           // snake_case intent name or command ID
    var target: String?
    var confidenceBoost: Double  // bonus applied on top of base confidence
    var usageCount: Int
    var source: AliasSource
    let createdAt: Date
    var lastUsedAt: Date?
    var approvalState: ApprovalState
}

@MainActor
final class LearnedCommandAliasStore {
    private(set) var aliases: [LearnedAlias] = []
    private let maxAliases = 500
    private static let fileName = "ll_aliases.json"

    init() { load() }

    // MARK: - Lookup

    func match(normalizedTranscript: String) -> LearnedAlias? {
        let norm = normalizedTranscript.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases
            .filter { $0.approvalState != .rejected }
            .first { alias in
                let p = alias.normalizedPhrase
                return norm == p || norm.hasPrefix(p + " ") || norm.contains(p)
            }
    }

    // MARK: - Write

    func add(phrase: String, intent: String, target: String?,
             source: AliasSource, confidenceBoost: Double = 0.15) {
        let norm = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = aliases.firstIndex(where: { $0.normalizedPhrase == norm && $0.intent == intent }) {
            aliases[i].usageCount += 1
            aliases[i].lastUsedAt = Date()
            persist(); return
        }
        let alias = LearnedAlias(
            id: UUID(), phrase: phrase, normalizedPhrase: norm,
            intent: intent, target: target, confidenceBoost: confidenceBoost,
            usageCount: 1, source: source, createdAt: Date(), lastUsedAt: Date(),
            approvalState: source == .userCorrection ? .approved : .pending
        )
        aliases.insert(alias, at: 0)
        if aliases.count > maxAliases { aliases.removeLast() }
        persist()
    }

    func incrementUsage(id: UUID) {
        guard let i = aliases.firstIndex(where: { $0.id == id }) else { return }
        aliases[i].usageCount += 1
        aliases[i].lastUsedAt = Date()
        persist()
    }

    func approve(id: UUID) { setState(id: id, .approved) }
    func reject(id: UUID)  { setState(id: id, .rejected) }
    func remove(id: UUID)  { aliases.removeAll { $0.id == id }; persist() }

    private func setState(id: UUID, _ state: ApprovalState) {
        guard let i = aliases.firstIndex(where: { $0.id == id }) else { return }
        aliases[i].approvalState = state; persist()
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        appSupportDir.appendingPathComponent(fileName)
    }

    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JarvisMac")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([LearnedAlias].self, from: data)
        else { return }
        aliases = decoded
    }
}
