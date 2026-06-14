import Foundation
import Observation

// MARK: - LiveEditAuditLog

/// Persistent, append-only audit trail of every attempted runtime edit
/// (applied, rejected, proposed, or rolled back). Backs the "show recent
/// changes" / "what did you edit" / "why did you change that" commands and the
/// Situation Room edit history.
@Observable
@MainActor
final class LiveEditAuditLog {

    static let shared = LiveEditAuditLog()

    private(set) var entries: [AuditEntry] = []   // newest first
    private let cap = 500
    let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Self.defaultURL()
        self.fileURL = resolved
        self.entries = Self.load(from: resolved)
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live_edit_audit.json")
    }

    // MARK: - Record / query

    func record(_ entry: AuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        scheduleSave()
    }

    func recent(limit: Int = 10) -> [AuditEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func entries(for systemID: String, limit: Int = 10) -> [AuditEntry] {
        Array(entries.lazy.filter { $0.systemID == systemID }.prefix(limit))
    }

    func entry(patchID: UUID) -> AuditEntry? {
        entries.first { $0.patchID == patchID }
    }

    /// Most recent applied/rolled-back change, for "why did you change that".
    var lastChange: AuditEntry? {
        entries.first { $0.action == "applied" || $0.action == "rolled_back" }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("[LiveEditAudit] save failed: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([AuditEntry].self, from: data)) ?? []
    }
}
