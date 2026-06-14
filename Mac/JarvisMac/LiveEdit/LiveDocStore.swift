import Foundation
import Observation

// MARK: - LiveDocStore

/// A generic single-document living store: one text/markdown document that is
/// persisted atomically, debounced, and **hot-reloaded** when the file changes
/// on disk. Used to back living systems that don't already have a dedicated
/// store (voice, commands, goals, skills, agents, memory rules, project state).
///
/// Mirrors the file-watch + atomic-write + self-write-echo-guard pattern used by
/// `HeartbeatStore` so external manual edits take effect with no app restart.
@Observable
@MainActor
final class LiveDocStore {

    let id: String
    let fileURL: URL
    private(set) var text: String

    private var saveTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var lastSelfWriteAt: Date = .distantPast

    init(id: String, defaultText: String, fileURL: URL? = nil) {
        self.id = id
        let resolved = fileURL ?? Self.defaultURL(id: id)
        self.fileURL = resolved
        if let existing = try? String(contentsOf: resolved, encoding: .utf8) {
            self.text = existing
        } else {
            self.text = defaultText
        }
        startFileWatch(seedIfMissing: defaultText)
    }

    nonisolated func cancelWatch() {
        Task { @MainActor in self.fileWatch?.cancel() }
    }

    deinit { cancelWatch() }

    // MARK: - Location

    private static func defaultURL(id: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("JarvisMac", isDirectory: true)
            .appendingPathComponent("LiveSystems", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live_\(id).md")
    }

    // MARK: - Mutation

    /// Apply new content: updates the in-memory value immediately (so the next
    /// read — and the next LLM context build — sees it) and persists to disk.
    func setText(_ newValue: String) {
        guard newValue != text else { return }
        text = newValue
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            lastSelfWriteAt = Date()
            try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("[LiveDoc:\(self.id)] save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Hot reload

    private func startFileWatch(seedIfMissing: String) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? seedIfMissing.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
        let fd = Darwin.open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileWatch = source
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            if Date().timeIntervalSince(self.lastSelfWriteAt) < 1.0 { return }
            if let reloaded = try? String(contentsOf: self.fileURL, encoding: .utf8),
               reloaded != self.text {
                self.text = reloaded
                Log.app.info("[LiveDoc:\(self.id)] hot-reloaded from disk")
            }
        }
    }
}
