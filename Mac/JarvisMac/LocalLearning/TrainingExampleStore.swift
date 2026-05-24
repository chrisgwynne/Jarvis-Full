import Foundation

struct TrainingExample: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let transcript: String
    let correctedTranscript: String?
    let intent: String
    let target: String?
    let spokenResponse: String
    let routingSource: InteractionSource
    var approvalState: ApprovalState
    var source: ExampleSource
    var notes: String?

    var jsonlLine: String {
        let obj: [String: Any?] = [
            "transcript": transcript,
            "corrected_transcript": correctedTranscript,
            "intent": intent,
            "target": target,
            "spoken_response": spokenResponse,
            "routing_source": routingSource.rawValue,
            "source": source.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        let compact = obj.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: compact),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }
}

@MainActor
final class TrainingExampleStore {
    private(set) var examples: [TrainingExample] = []
    private let maxExamples = 2000
    private static let fileName = "ll_training_examples.json"

    init() { load() }

    func add(_ example: TrainingExample) {
        examples.insert(example, at: 0)
        if examples.count > maxExamples { examples.removeLast() }
        persist()
    }

    func approve(id: UUID) { setState(id: id, .approved) }
    func reject(id: UUID)  { setState(id: id, .rejected) }

    func update(id: UUID, notes: String) {
        guard let i = examples.firstIndex(where: { $0.id == id }) else { return }
        examples[i].notes = notes
        persist()
    }

    func remove(id: UUID) {
        examples.removeAll { $0.id == id }
        persist()
    }

    func clearFailed() {
        examples.removeAll { $0.approvalState == .rejected }
        persist()
    }

    func approved() -> [TrainingExample]  { examples.filter { $0.approvalState == .approved } }
    func pending() -> [TrainingExample]   { examples.filter { $0.approvalState == .pending } }
    func rejected() -> [TrainingExample]  { examples.filter { $0.approvalState == .rejected } }

    func exportJSONL(approved: Bool = true, pending: Bool = false) -> String {
        examples
            .filter { ex in
                (approved && ex.approvalState == .approved) ||
                (pending  && ex.approvalState == .pending)
            }
            .map(\.jsonlLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func validate() -> [String] {
        var issues: [String] = []
        for ex in examples {
            if ex.transcript.isEmpty       { issues.append("[\(ex.id)] empty transcript") }
            if ex.intent.isEmpty           { issues.append("[\(ex.id)] empty intent") }
            if ex.spokenResponse.isEmpty   { issues.append("[\(ex.id)] empty response") }
        }
        return issues
    }

    private func setState(id: UUID, _ state: ApprovalState) {
        guard let i = examples.firstIndex(where: { $0.id == id }) else { return }
        examples[i].approvalState = state; persist()
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JarvisMac/\(fileName)")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(examples) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([TrainingExample].self, from: data)
        else { return }
        examples = decoded
    }
}
