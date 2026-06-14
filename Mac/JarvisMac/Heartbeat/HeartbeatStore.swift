import Foundation
import Observation

// MARK: - HeartbeatStore

/// Durable, hot-reloadable home for `HeartbeatState`.
///
/// This is a *living runtime layer*: the state is persisted to
/// `Application Support/JarvisMac/heartbeat.json`, written atomically with a
/// short debounce, and the file is watched so an external edit (or another
/// process) is picked up without a restart — matching the Jarvis "living
/// system" principle.
///
/// All mutations funnel through this store so persistence and bounds enforcement
/// happen in exactly one place. The store is `@Observable` so SwiftUI surfaces
/// (a future Situation Room) update live.
@Observable
@MainActor
final class HeartbeatStore {

    static let shared = HeartbeatStore()

    private(set) var state: HeartbeatState

    // Bounds — keep the heartbeat tight; it is a pulse, not a log.
    private let maxAttention = 8
    private let maxBlockers  = 8
    private let maxIssues    = 12
    private let maxWins      = 12

    let fileURL: URL

    private var saveDebounce: Task<Void, Never>?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var reloadDebounce: Task<Void, Never>?
    private var lastSelfWriteAt: Date = .distantPast

    init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolved
        self.state = Self.load(from: resolved) ?? HeartbeatState()
        startFileWatch()
    }

    nonisolated func cancelWatch() {
        Task { @MainActor in self.fileWatch?.cancel() }
    }

    deinit { cancelWatch() }

    // MARK: - Default location

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("heartbeat.json")
    }

    // MARK: - Reads

    /// The `[HEARTBEAT]` block for LLM injection (empty when nothing to report).
    func contextBlock() -> String { state.contextBlock() }

    /// A short spoken status line for "what's my situation?".
    func situationSummary() -> String { state.situationSummary() }

    // MARK: - Mutations

    func setFocus(_ focus: String?) {
        let v = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.currentFocus != v else { return }
        state.currentFocus = (v?.isEmpty == true) ? nil : v
        touch()
    }

    func setActiveProject(_ project: String?, confidence: Double) {
        let v = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (v?.isEmpty == true) ? nil : v
        let conf = max(0, min(1, confidence))
        guard state.activeProject != normalized || abs(state.focusConfidence - conf) > 0.001 else { return }
        state.activeProject = normalized
        state.focusConfidence = conf
        touch()
    }

    func setTodaySummary(_ summary: String?) {
        let v = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (v?.isEmpty == true) ? nil : v
        guard state.todaySummary != normalized else { return }
        state.todaySummary = normalized
        touch()
    }

    func recordInteraction(focus: String? = nil) {
        state.interactionCount += 1
        state.lastInteractionAt = Date()
        if let focus { setFocus(focus); return }  // setFocus already touches
        touch()
    }

    func recordSessionStart() {
        state.sessionCount += 1
        touch()
    }

    func addAttention(_ text: String, source: String = "proactivity", confidence: Double = 0.8) {
        addItem(text, source: source, confidence: confidence, to: \.attentionNeeded, cap: maxAttention)
    }

    func addBlocker(_ text: String, source: String = "system", confidence: Double = 0.8) {
        addItem(text, source: source, confidence: confidence, to: \.blockers, cap: maxBlockers)
    }

    func addOpenIssue(_ text: String, source: String = "system", confidence: Double = 0.8) {
        addItem(text, source: source, confidence: confidence, to: \.openIssues, cap: maxIssues)
    }

    func addWin(_ text: String, source: String = "system", confidence: Double = 0.8) {
        addItem(text, source: source, confidence: confidence, to: \.recentWins, cap: maxWins)
    }

    /// Resolve (remove) any open issue / blocker / attention item whose text
    /// contains `needle` (case-insensitive). Returns the number removed.
    @discardableResult
    func resolve(matching needle: String) -> Int {
        let key = needle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return 0 }
        let before = state.openIssues.count + state.blockers.count + state.attentionNeeded.count
        state.openIssues.removeAll { $0.text.lowercased().contains(key) }
        state.blockers.removeAll { $0.text.lowercased().contains(key) }
        state.attentionNeeded.removeAll { $0.text.lowercased().contains(key) }
        let removed = before - (state.openIssues.count + state.blockers.count + state.attentionNeeded.count)
        if removed > 0 { touch() }
        return removed
    }

    func clearAttention() {
        guard !state.attentionNeeded.isEmpty else { return }
        state.attentionNeeded.removeAll()
        touch()
    }

    /// Reset to a blank pulse (keeps the file; for tests / "start fresh").
    func reset() {
        state = HeartbeatState()
        touch()
    }

    // MARK: - Item helper

    private func addItem(_ text: String,
                         source: String,
                         confidence: Double,
                         to keyPath: WritableKeyPath<HeartbeatState, [HeartbeatItem]>,
                         cap: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()

        // Dedup: refresh the timestamp of an existing matching item instead of
        // appending a duplicate.
        if let idx = state[keyPath: keyPath].firstIndex(where: { $0.text.lowercased() == key }) {
            state[keyPath: keyPath][idx].createdAt = Date()
            touch()
            return
        }

        state[keyPath: keyPath].append(
            HeartbeatItem(text: trimmed, source: source, confidence: confidence)
        )
        // Trim oldest-first to the cap.
        if state[keyPath: keyPath].count > cap {
            state[keyPath: keyPath].sort { $0.createdAt > $1.createdAt }
            state[keyPath: keyPath] = Array(state[keyPath: keyPath].prefix(cap))
        }
        touch()
    }

    // MARK: - Persistence

    private func touch() {
        state.updatedAt = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        saveDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            lastSelfWriteAt = Date()
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("[Heartbeat] save failed: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> HeartbeatState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HeartbeatState.self, from: data)
    }

    // MARK: - Hot reload (file watch)

    private func startFileWatch() {
        // Ensure the file exists so the descriptor is valid; write current state.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            saveNow()
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
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            // Ignore the echo from our own atomic write.
            if Date().timeIntervalSince(self.lastSelfWriteAt) < 1.0 { return }
            if let reloaded = Self.load(from: self.fileURL), reloaded != self.state {
                self.state = reloaded
                Log.app.info("[Heartbeat] hot-reloaded from disk")
            }
        }
    }
}
