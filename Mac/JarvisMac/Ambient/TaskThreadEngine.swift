import Foundation

// MARK: - TaskThread

/// A coherent work context inferred from what the user is doing across apps.
/// Built incrementally from SystemBus events; discarded when idle > 30 min.
struct TaskThread: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var title: String
    let startedAt: Date
    var lastActivityAt: Date
    var apps: [String]           // ordered, deduped, newest-first
    var entities: [String]       // files, URLs, repos seen in this thread
    var errors: [String]         // errors detected during this thread
    var confidence: Double       // 0–1: how sure we are this is a cohesive task
    var isActive: Bool

    var idleSeconds: TimeInterval { Date().timeIntervalSince(lastActivityAt) }
    var durationSeconds: TimeInterval { lastActivityAt.timeIntervalSince(startedAt) }

    var summary: String {
        var parts: [String] = []
        if let first = apps.first { parts.append("in \(first)") }
        if !entities.isEmpty { parts.append("on \(entities.prefix(2).joined(separator: ", "))") }
        if !errors.isEmpty { parts.append("⚠️ \(errors.count) error\(errors.count == 1 ? "" : "s")") }
        return parts.isEmpty ? title : "\(title) \(parts.joined(separator: " "))"
    }

    /// Natural-language description of when this thread was active, for TTS.
    var spokenTimeAgo: String {
        let seconds = Int(-lastActivityAt.timeIntervalSinceNow)
        if seconds < 60     { return "just now" }
        if seconds < 3600   { return "\(seconds / 60) minutes ago" }
        if seconds < 86400  { return "\(seconds / 3600) hours ago" }
        return "\(seconds / 86400) days ago"
    }
}

// MARK: - TaskThreadEngine

/// Subscribes to AmbientContextEngine events and builds TaskThread models
/// representing what the user is working on over time.
///
/// A new thread is started when:
/// - The app changes and the new app is unrelated to the current thread
/// - The current thread has been idle > 30 minutes
///
/// The current thread is updated on every screen context update.
///
/// Threads are persisted to a JSON ring-buffer on disk so they survive
/// app restarts, enabling "what was I working on last time?" queries.
@MainActor
final class TaskThreadEngine {

    private(set) var threads: [TaskThread] = []
    private(set) var currentThread: TaskThread?

    var maxThreadAge: TimeInterval = 1800   // 30 min idle = end thread
    var maxThreads: Int = 50                // raised from 20 to match pruning cap
    var pruneAge: TimeInterval = 14 * 86400 // 14 days

    private var busTokens: [SystemBus.SubscriptionToken] = []

    // MARK: - Persistence

    /// Serial queue for all disk I/O — never blocks the main thread.
    private let ioQueue = DispatchQueue(label: "com.jarvis.taskthreads.io", qos: .utility)
    private let storeURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in:  .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("task_threads.json")
    }()

    // MARK: - Lifecycle

    func start() {
        loadRecentThreads()

        guard busTokens.isEmpty else { return }

        busTokens.append(SystemBus.shared.subscribe(AppFocusChangedEvent.self) { [weak self] event in
            self?.handleAppFocus(event)
        })
        busTokens.append(SystemBus.shared.subscribe(ScreenContextUpdatedEvent.self) { [weak self] event in
            self?.handleScreenUpdate(event)
        })
        busTokens.append(SystemBus.shared.subscribe(ScreenErrorDetectedEvent.self) { [weak self] event in
            self?.handleScreenError(event)
        })
    }

    func stop() {
        // Persist the in-flight thread before stopping so it's available next launch.
        if let current = currentThread {
            var closing = current
            closing.isActive = false
            persistThread(closing, phase: "thread_suspend")
        }
        busTokens.forEach { SystemBus.shared.unsubscribe($0) }
        busTokens.removeAll()
    }

    // MARK: - Thread management

    private func handleAppFocus(_ event: AppFocusChangedEvent) {
        let appName = event.activeApp
        guard !appName.isEmpty else { return }

        if var thread = currentThread {
            // If idle too long, close and start fresh
            if thread.idleSeconds > maxThreadAge {
                closeCurrentThread()
                startNewThread(app: appName, title: inferTitle(app: appName))
                return
            }
            // Add app to existing thread if not already there
            if !thread.apps.contains(appName) {
                thread.apps.insert(appName, at: 0)
                if thread.apps.count > 8 { thread.apps = Array(thread.apps.prefix(8)) }
            }
            thread.lastActivityAt = Date()
            thread.isActive = true
            currentThread = thread
        } else {
            startNewThread(app: appName, title: inferTitle(app: appName))
        }
    }

    private func handleScreenUpdate(_ event: ScreenContextUpdatedEvent) {
        guard var thread = currentThread else {
            // No active thread — start one from the screen context
            let appName = event.summary.activeApp
            if !appName.isEmpty {
                startNewThread(app: appName, title: event.summary.detectedTask.nonEmpty ?? inferTitle(app: appName))
            }
            return
        }

        // Update task title if we have a richer description now
        if !event.summary.detectedTask.isEmpty {
            thread.title = event.summary.detectedTask
        }

        // Merge new entities
        for entity in event.summary.visibleEntities {
            if !thread.entities.contains(entity) {
                thread.entities.insert(entity, at: 0)
                if thread.entities.count > 20 { thread.entities = Array(thread.entities.prefix(20)) }
            }
        }

        thread.lastActivityAt = event.summary.timestamp
        thread.confidence = min(1.0, thread.confidence + 0.05)
        currentThread = thread
    }

    private func handleScreenError(_ event: ScreenErrorDetectedEvent) {
        guard var thread = currentThread else { return }
        let errorLine = "\(event.appName): \(event.errorText.prefix(100))"
        if !thread.errors.contains(errorLine) {
            thread.errors.insert(errorLine, at: 0)
            if thread.errors.count > 10 { thread.errors = Array(thread.errors.prefix(10)) }
        }
        thread.lastActivityAt = Date()
        currentThread = thread
    }

    private func startNewThread(app: String, title: String) {
        // Before creating a brand-new thread, check whether there's a recent thread
        // (within the last 30 minutes) whose primary app matches. If so, resume it
        // instead of creating a near-duplicate entry for the same work context.
        if let recent = findRecentSimilarThread(primaryApp: app) {
            if let prev = currentThread, prev.id != recent.id {
                archive(prev)
            }
            var resumed = recent
            resumed.isActive = true
            resumed.lastActivityAt = Date()
            // Merge the app at the front so the resumed thread reflects the current focus.
            if !resumed.apps.contains(app) {
                resumed.apps.insert(app, at: 0)
                if resumed.apps.count > 8 { resumed.apps = Array(resumed.apps.prefix(8)) }
            }
            currentThread = resumed
            // Remove the stale archived copy; it will be re-archived on next close.
            threads.removeAll { $0.id == resumed.id }
            return
        }

        let thread = TaskThread(
            id: UUID(),
            title: title,
            startedAt: Date(),
            lastActivityAt: Date(),
            apps: [app],
            entities: [],
            errors: [],
            confidence: 0.3,
            isActive: true
        )
        if let prev = currentThread {
            archive(prev)
        }
        currentThread = thread

        // Persist the start event so we know a new session began.
        persistThread(thread, phase: "thread_start")
    }

    /// Returns the most recent archived thread whose primary app matches and whose
    /// last activity was within the last 30 minutes.  Used to avoid creating
    /// near-duplicate threads for brief app switches and returns.
    private func findRecentSimilarThread(primaryApp: String) -> TaskThread? {
        let cutoff = Date().addingTimeInterval(-1800) // 30 minutes
        return threads.first { thread in
            thread.lastActivityAt > cutoff &&
            thread.apps.first?.lowercased() == primaryApp.lowercased()
        }
    }

    private func closeCurrentThread() {
        guard var thread = currentThread else { return }
        thread.isActive = false
        archive(thread)
        currentThread = nil

        // Persist the completed thread and record a memory candidate.
        persistThread(thread, phase: "thread_end")
        saveThreadMemory(thread)
    }

    private func archive(_ thread: TaskThread) {
        var closed = thread
        closed.isActive = false
        // Remove any earlier entry for this thread ID before re-inserting.
        threads.removeAll { $0.id == closed.id }
        threads.insert(closed, at: 0)
        if threads.count > maxThreads {
            threads = Array(threads.prefix(maxThreads))
        }
        scheduleSave()
    }

    // MARK: - Persistence helpers

    /// Load persisted threads from disk, pruning stale entries on the way in.
    func loadRecentThreads() {
        let url = storeURL
        ioQueue.async { [weak self] in
            guard let self else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard
                let data = try? Data(contentsOf: url),
                let loaded = try? decoder.decode([TaskThread].self, from: data)
            else { return }

            let cutoff = Date().addingTimeInterval(-self.pruneAge)
            let fresh = loaded
                .filter { $0.lastActivityAt > cutoff }
                .prefix(self.maxThreads)
                .map { var t = $0; t = TaskThread(
                    id: t.id, title: t.title, startedAt: t.startedAt,
                    lastActivityAt: t.lastActivityAt, apps: t.apps,
                    entities: t.entities, errors: t.errors,
                    confidence: t.confidence, isActive: false
                ); return t }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Merge loaded threads without clobbering any live thread started
                // since app launch (isActive ones stay at the front).
                let liveIDs = Set(self.threads.map(\.id))
                let toInsert = fresh.filter { !liveIDs.contains($0.id) }
                self.threads.append(contentsOf: toInsert)
                self.threads.sort { $0.lastActivityAt > $1.lastActivityAt }
                if self.threads.count > self.maxThreads {
                    self.threads = Array(self.threads.prefix(self.maxThreads))
                }
            }
        }
    }

    /// Persist the current threads array to disk asynchronously.
    private func scheduleSave() {
        let snapshot = threads
        let url = storeURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Persist a single thread event to `context_snapshots` via `ContextSnapshotStore`
    /// if one is accessible, otherwise fire-and-forget via `ConversationMemoryStore`.
    private func persistThread(_ thread: TaskThread, phase: String) {
        // Use ConversationMemoryStore.shared which has a guaranteed singleton.
        // We save as a temporaryNote so it's searchable but low-priority.
        guard phase == "thread_start" || phase == "thread_end" || phase == "thread_suspend" else { return }
        // Only save thread_end / thread_suspend to avoid excessive writes on every start.
        guard phase != "thread_start" || thread.confidence >= 0.6 else { return }

        // Snapshot is also captured via the JSON store (scheduleSave) so the
        // ConversationMemoryStore entry serves as a secondary, searchable record.
        Task { @MainActor in
            let candidate = MemoryCandidate(
                id: UUID(),
                type: .temporaryNote,
                tier: .rawTranscript,
                title: "Work session: \(thread.title)",
                summary: "[\(phase)] \(thread.summary) — \(thread.spokenTimeAgo). Apps: \(thread.apps.prefix(4).joined(separator: ", ")). Duration: \(Int(thread.durationSeconds / 60)) min.",
                rawText: thread.summary,
                confidence: min(thread.confidence + 0.3, 1.0),  // boost past the 0.60 gate
                tags: ["task_thread", phase] + thread.apps.prefix(3),
                createdAt: thread.lastActivityAt
            )
            ConversationMemoryStore.shared.saveMemory(candidate)
        }
    }

    /// Save a meaningful completed thread as a `projectProgress` memory candidate
    /// so the LLM can surface it in "what was I working on last time?" queries.
    private func saveThreadMemory(_ thread: TaskThread) {
        // Only worth recording if we have reasonable confidence and some duration.
        guard thread.confidence >= 0.4, thread.durationSeconds >= 120 else { return }
        Task { @MainActor in
            let candidate = MemoryCandidate(
                id: UUID(),
                type: .projectProgress,
                tier: .dailySummary,
                title: thread.title,
                summary: "Work session on '\(thread.title)' using \(thread.apps.prefix(3).joined(separator: ", ")). Duration \(Int(thread.durationSeconds / 60)) min. Entities: \(thread.entities.prefix(3).joined(separator: ", ")).",
                rawText: thread.summary,
                confidence: min(thread.confidence + 0.2, 1.0),
                tags: ["task_thread", "work_session"] + thread.apps.prefix(3),
                createdAt: thread.lastActivityAt
            )
            ConversationMemoryStore.shared.saveMemory(candidate)
        }
    }

    /// Remove threads older than `pruneAge` and cap at `maxThreads`.
    func pruneOldThreads() {
        let cutoff = Date().addingTimeInterval(-pruneAge)
        threads.removeAll { !$0.isActive && $0.lastActivityAt < cutoff }
        if threads.count > maxThreads {
            threads = Array(threads.prefix(maxThreads))
        }
        scheduleSave()
    }

    // MARK: - Helpers

    private func inferTitle(app: String) -> String {
        let low = app.lowercased()
        if low.contains("xcode")   { return "Coding in Xcode" }
        if low.contains("cursor")  { return "Coding in Cursor" }
        if low.contains("vscode")  { return "Coding in VS Code" }
        if low.contains("terminal") || low.contains("iterm") { return "Terminal session" }
        if low.contains("safari") || low.contains("chrome") || low.contains("arc") { return "Browsing" }
        if low.contains("slack")   { return "Messaging in Slack" }
        if low.contains("figma")   { return "Designing in Figma" }
        if low.contains("mail")    { return "Email" }
        return "Using \(app)"
    }

    // MARK: - Public query

    var activeThreadSummary: String {
        currentThread?.summary ?? "No active task"
    }

    func recentThreads(limit: Int = 5) -> [TaskThread] {
        Array(threads.prefix(limit))
    }

    /// Natural-language answer to "what was I working on last time?".
    var lastWorkSummary: String {
        // Prefer the most recent closed thread; fall back to active thread.
        let candidate = threads.first { !$0.isActive } ?? threads.first
        guard let last = candidate else {
            return "I don't have a record of recent work sessions."
        }
        let apps = last.apps.prefix(3).joined(separator: ", ")
        return "Last time you were working on \(last.title) with \(apps), \(last.spokenTimeAgo)."
    }

    /// Find the most recent thread whose title or app list matches the query.
    func threadForQuery(_ query: String) -> TaskThread? {
        let q = query.lowercased()
        return threads.reversed().first { t in
            t.title.localizedCaseInsensitiveContains(q) ||
            t.apps.contains(where: { $0.localizedCaseInsensitiveContains(q) }) ||
            t.entities.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }
}

// MARK: - String helper

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
