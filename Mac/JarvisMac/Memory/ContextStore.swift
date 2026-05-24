import Foundation

/// Bounded ring of context entries persisted to a single JSONL file under
/// Application Support. Easy to swap for SQLite later.
struct ContextEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let summary: String

    enum Kind: String, Codable {
        case transcript
        case intent
        case action
        case camera
        case cameraScene
        case cameraPresence
        case cameraWatch
        case cameraMotion
        case screen
        case home
        case android
        case activeApp
        case bargeIn
        case wake
        case error
    }

    init(kind: Kind, summary: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.summary = summary
    }
}

final class ContextStore {
    private let url: URL
    private let lock = NSLock()
    private let limit: Int
    private(set) var entries: [ContextEntry] = []
    private let queue = DispatchQueue(label: "com.jarvis.mac.context", qos: .utility)

    init(limit: Int = 250) {
        self.limit = limit
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("context.jsonl")
        load()
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded: [ContextEntry] = []
        for line in text.split(separator: "\n") {
            if let entry = try? dec.decode(ContextEntry.self,
                                           from: Data(line.utf8)) {
                loaded.append(entry)
            }
        }
        if loaded.count > limit { loaded = Array(loaded.suffix(limit)) }
        entries = loaded
    }

    func append(_ entry: ContextEntry) {
        lock.lock()
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    func recent(_ kind: ContextEntry.Kind? = nil, limit: Int = 20) -> [ContextEntry] {
        lock.lock(); defer { lock.unlock() }
        let filtered = kind.map { k in entries.filter { $0.kind == k } } ?? entries
        return Array(filtered.suffix(limit))
    }

    private func persist(_ snapshot: [ContextEntry]) {
        queue.async { [url] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            var bytes = Data()
            for entry in snapshot {
                if let line = try? enc.encode(entry) {
                    bytes.append(line)
                    bytes.append(0x0A) // newline
                }
            }
            try? bytes.write(to: url, options: [.atomic])
        }
    }
}
