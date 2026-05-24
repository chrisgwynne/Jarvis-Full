import Foundation

/// Persists per-detection feedback (false accepts / false rejects) for
/// threshold tuning and future model training. JSONL under Application
/// Support so it's easy to inspect or post-process offline.
struct WakeWordFeedbackEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let feedback: String      // "falseAccept" | "falseReject"
    let keyword: String?
    let confidence: Double?

    init(feedback: WakeWordFeedback, event: WakeWordEvent?) {
        self.id = UUID()
        self.timestamp = Date()
        self.feedback = feedback.rawValue
        self.keyword = event?.keyword
        self.confidence = event?.confidence
    }
}

final class WakeWordFeedbackLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.jarvis.mac.wake.feedback", qos: .utility)

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("wake-feedback.jsonl")
    }

    func append(_ entry: WakeWordFeedbackEntry) {
        queue.async { [url] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard var line = try? enc.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: [.atomic])
            }
        }
    }
}
