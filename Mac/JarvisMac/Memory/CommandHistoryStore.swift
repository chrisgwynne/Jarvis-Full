import Foundation

struct CommandRecord: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let transcript: String
    let intentDescription: String
}

/// Bounded ring of past transcripts/intents — surfaces in the debug UI and
/// gives the future LLM context window something to work with.
final class CommandHistoryStore {
    private let limit: Int
    private(set) var records: [CommandRecord] = []
    private let lock = NSLock()

    init(limit: Int = 200) { self.limit = limit }

    func append(transcript: String, intent: Intent) {
        lock.lock(); defer { lock.unlock() }
        records.append(CommandRecord(timestamp: Date(),
                                     transcript: transcript,
                                     intentDescription: String(describing: intent)))
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
    }

    func recent(_ n: Int = 20) -> [CommandRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.suffix(n))
    }
}
