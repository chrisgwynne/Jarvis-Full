import Foundation

/// Watches the Obsidian vault for notable changes and surfaces them as
/// proactivity signals.
///
/// Fires on:
/// - Notes modified in the last 5 minutes (external edits, new content from other tools)
/// - Notes tagged with a "watch tag" (e.g. `#jarvis`, `#review`, `#urgent`)
///   that are new since last poll
///
/// Uses `isFirstPoll` to silently seed state on launch.
@MainActor
final class ObsidianProactivityProvider: ProactivitySignalProvider {

    var source: SignalSource { .obsidian }

    // MARK: - Private

    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private let prefs: PreferencesStore
    private let vault: ObsidianVaultService

    private var pollTask: Task<Void, Never>?
    /// note-id → last-seen modifiedAt
    private var seenModifiedDates: [String: Date] = [:]
    /// Persistent dedup of notes we've already alerted for watch-tags.
    /// Survives restarts so a tagged note doesn't re-announce every launch.
    private let dedup = ProactivityDedupStore(name: "obsidian.watchtags")
    private var isFirstPoll = true

    // MARK: - Init

    init(engine: ProactivityEngine,
         appState: AppState,
         prefs: PreferencesStore,
         vault: ObsidianVaultService) {
        self.engine   = engine
        self.appState = appState
        self.prefs    = prefs
        self.vault    = vault
    }

    // MARK: - ProactivitySignalProvider

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNow()
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard prefs.current.obsidianProactivityEnabled,
              vault.isIndexed else { return }

        let watchTags = prefs.current.obsidianWatchTags
        let now       = Date()

        for note in vault.notes.values {

            // ── Watch-tag alerts ─────────────────────────────────────────────
            // Alert once per note that carries a watch tag (e.g. #jarvis, #urgent).
            if !isFirstPoll {
                let hasWatchTag = note.tags.contains(where: { tag in
                    watchTags.contains(where: { $0.lowercased() == tag.lowercased() })
                })
                if hasWatchTag, !dedup.contains(note.id) {
                    // Persistent insert — handles cap + atomic write off-main.
                    dedup.insert(note.id)
                    let matchedTag = note.tags.first(where: { tag in
                        watchTags.contains(where: { $0.lowercased() == tag.lowercased() })
                    }) ?? watchTags.first ?? ""
                    let signal = ProactivitySignal(
                        source: .obsidian,
                        title: "Obsidian: \(note.title)",
                        body: "Note tagged #\(matchedTag): \(note.snippet)",
                        category: "obsidian.watchtag",
                        priority: matchedTag.lowercased() == "urgent" ? .high : .normal,
                        dedupeKey: "obsidian.tag.\(note.id).\(matchedTag)",
                        spokenText: "Your Obsidian note \"\(note.title)\" is tagged \(matchedTag)."
                    )
                    ProactivityOrchestrator.shared.providerPublish(signal: signal)
                }
            }

            // ── Recently modified notes ─────────────────────────────────────
            // Alert when a note changes externally (not just on first poll).
            if !isFirstPoll,
               let lastSeen = seenModifiedDates[note.id],
               note.modifiedAt > lastSeen,
               now.timeIntervalSince(note.modifiedAt) < 300 { // modified in last 5 min
                let signal = ProactivitySignal(
                    source: .obsidian,
                    title: "Obsidian updated: \(note.title)",
                    body: note.snippet,
                    category: "obsidian.modified",
                    priority: .low,
                    dedupeKey: "obsidian.mod.\(note.id).\(Int(note.modifiedAt.timeIntervalSinceReferenceDate / 60))",
                    spokenText: "Your note \"\(note.title)\" was just updated."
                )
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }

            seenModifiedDates[note.id] = note.modifiedAt
        }

        // Drop entries for notes that no longer exist in the vault — without this
        // the dict accumulates ghosts of deleted notes for the lifetime of the app.
        let liveIds = Set(vault.notes.keys)
        if seenModifiedDates.count > liveIds.count {
            seenModifiedDates = seenModifiedDates.filter { liveIds.contains($0.key) }
        }

        isFirstPoll = false
    }
}
