import Foundation

// MARK: - Reply source

/// Where the spoken text originated from.
enum ReplySource: String, Codable {
    case command        // routed command response (renderer/ResponsePlaybook)
    case template       // explicit ResponseKey lookup
    case llm            // LLM-generated response
    case tool           // tool execution result
    case proactive      // unsolicited nudge or suggestion
    case error          // error/failure path
    case wake           // wake word acknowledgement
    case system         // internal system message (not editable)
}

// MARK: - Log entry

struct ReplyLogEntry: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var source: ReplySource
    var intent: String?
    var responseKey: String?
    var spokenText: String
    var device: String
    var editableFlag: Bool          // false for system-only entries
    var correctedText: String?      // set when user edits via Reply Review
    var accepted: Bool?             // nil = not yet rated

    // Computed for export
    var isSystemOnly: Bool { !editableFlag }
}

// MARK: - Logger

/// Appends every spoken reply to a bounded JSONL file.
/// All reads and writes are on a dedicated serial queue — never call from main thread.
final class JarvisReplyLogger {

    static let shared = JarvisReplyLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "jarvis.reply-log", qos: .utility)
    private let maxBytes = 4 * 1024 * 1024  // 4 MB cap
    private let maxEntries = 2_000
    private var _cache: [ReplyLogEntry] = []
    private var _cacheLoaded = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("reply_log.jsonl")
    }

    // MARK: Append

    func append(
        source: ReplySource,
        intent: String? = nil,
        responseKey: String? = nil,
        spokenText: String,
        editableFlag: Bool = true
    ) {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = ReplyLogEntry(
            id: UUID(),
            timestamp: Date(),
            source: source,
            intent: intent,
            responseKey: responseKey,
            spokenText: spokenText,
            device: "mac",
            editableFlag: editableFlag,
            correctedText: nil,
            accepted: nil
        )
        queue.async { [weak self] in
            self?.write(entry: entry)
        }
    }

    private func write(entry: ReplyLogEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        }
        // Append to in-memory cache if loaded
        if _cacheLoaded {
            _cache.append(entry)
            if _cache.count > maxEntries {
                _cache.removeFirst(_cache.count - maxEntries)
            }
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return }
        // Keep second half of file
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let keep = Array(lines.dropFirst(lines.count / 2))
        let trimmed = keep.joined(separator: "\n") + "\n"
        try? trimmed.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        _cacheLoaded = false  // invalidate cache
    }

    // MARK: Read

    func recentEntries(limit: Int = 100, completion: @escaping ([ReplyLogEntry]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if !_cacheLoaded { _loadCache() }
            let result = Array(_cache.suffix(limit))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func allEntries(completion: @escaping ([ReplyLogEntry]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if !_cacheLoaded { _loadCache() }
            let result = _cache
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func _loadCache() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            _cache = []; _cacheLoaded = true; return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _cache = content.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(ReplyLogEntry.self, from: Data($0.utf8))
        }
        if _cache.count > maxEntries {
            _cache = Array(_cache.suffix(maxEntries))
        }
        _cacheLoaded = true
    }

    // MARK: Edit

    func updateCorrection(id: UUID, correctedText: String, accepted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if !_cacheLoaded { _loadCache() }
            if let idx = _cache.firstIndex(where: { $0.id == id }) {
                _cache[idx].correctedText = correctedText
                _cache[idx].accepted = accepted
                _rewriteFile()
            }
        }
    }

    private func _rewriteFile() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = _cache.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    // MARK: Export

    /// Returns a JSONL string of all entries suitable for training export.
    func exportJSONL(completion: @escaping (String) -> Void) {
        allEntries { entries in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let lines = entries.compactMap { e -> String? in
                guard let data = try? encoder.encode(e),
                      let s = String(data: data, encoding: .utf8) else { return nil }
                return s
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    /// Returns a CSV string of all entries.
    func exportCSV(completion: @escaping (String) -> Void) {
        allEntries { entries in
            var rows = ["timestamp,source,intent,responseKey,spokenText,correctedText,accepted,device,editableFlag"]
            for e in entries {
                let ts = ISO8601DateFormatter().string(from: e.timestamp)
                let row = [
                    ts,
                    e.source.rawValue,
                    e.intent ?? "",
                    e.responseKey ?? "",
                    Self.csvEscape(e.spokenText),
                    e.correctedText.map { Self.csvEscape($0) } ?? "",
                    e.accepted.map { $0 ? "true" : "false" } ?? "",
                    e.device,
                    e.editableFlag ? "true" : "false"
                ].joined(separator: ",")
                rows.append(row)
            }
            completion(rows.joined(separator: "\n"))
        }
    }

    private static func csvEscape(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
