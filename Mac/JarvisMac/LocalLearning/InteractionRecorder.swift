import Foundation

struct InteractionRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let originalTranscript: String
    var correctedTranscript: String?
    let detectedIntent: String
    let routingSource: InteractionSource
    var spokenResponse: String
    var success: Bool
    var userCorrection: String?
    var privacyRedacted: Bool

    init(
        transcript: String,
        intent: String,
        source: InteractionSource,
        response: String = "",
        success: Bool = true,
        privacyRedacted: Bool = false
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.originalTranscript = transcript
        self.detectedIntent = intent
        self.routingSource = source
        self.spokenResponse = response
        self.success = success
        self.privacyRedacted = privacyRedacted
    }
}

@MainActor
final class InteractionRecorder {
    private(set) var records: [InteractionRecord] = []
    private let maxRecords = 500

    func record(_ interaction: InteractionRecord) {
        records.append(interaction)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
    }

    func updateLast(response: String? = nil, success: Bool? = nil, correction: String? = nil) {
        guard !records.isEmpty else { return }
        let i = records.count - 1
        if let r = response   { records[i].spokenResponse = r }
        if let s = success    { records[i].success = s }
        if let c = correction { records[i].userCorrection = c }
    }

    func last() -> InteractionRecord? { records.last }
    func recent(limit: Int) -> [InteractionRecord] { Array(records.suffix(limit)) }

    var successRate: Double {
        guard !records.isEmpty else { return 1.0 }
        return Double(records.filter(\.success).count) / Double(records.count)
    }
}
