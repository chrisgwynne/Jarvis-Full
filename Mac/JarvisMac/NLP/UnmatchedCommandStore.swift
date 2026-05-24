import Foundation
import Observation

/// One entry per command that the pipeline couldn't route. Persisted
/// so the user can later look back at what phrasing Jarvis didn't
/// understand and teach it new patterns.
struct UnmatchedCommandEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    var lastSeenAt: Date
    let rawText: String
    let normalizedText: String
    let action: String?         // CommandAction.rawValue, or nil
    let target: String?         // CommandTarget.Kind.rawValue, or nil
    let targetLabel: String?    // channel/app name when applicable
    let activeOverlay: String?  // top overlay kind, if any
    let phase: String?          // AssistantPhase.rawValue at the time
    var llmResolvedIntent: String?  // what the LLM figured out (e.g. "turn off living room lights")
    var frequency: Int              // how many times this phrase has been seen

    // ── Enriched diagnostic context (added when the FINAL unknown fallback fires) ──
    /// Active app/window at the time of the unmatched command.
    var currentApp: String? = nil
    /// Best guess from `IntentRouter`/phrase store before falling through.
    var matchedCommandCandidate: String? = nil
    /// `ContextEngine.snapshot.summaryString()` — short, no PII beyond what
    /// the engine itself stores.
    var activeContext: String? = nil
    /// AssistantPhase or "passive_wake" etc. — the listening mode at the time.
    var listeningMode: String? = nil
    /// Last successfully-executed Intent label.
    var lastIntent: String? = nil
    /// LLMDecision.label when an LLM hop was made.
    var llmDecision: String? = nil
    /// True iff the Android bridge reported connected at the time.
    var androidConnected: Bool? = nil
    /// User's likely intent, inferred from QuestionClassifier or the raw shape.
    var userExpectedAction: String? = nil
    /// `CFBundleShortVersionString` + build number for issue triage.
    var appVersion: String? = nil
    /// Latest URL of any GitHub issue we filed for this normalised command.
    /// Nil until the first issue is created.  Once present we never file
    /// another issue for the same normalisedText (dedupe).
    var githubIssueURL: String? = nil
    /// GitHub issue number (separate from URL so we can comment on it later).
    var githubIssueNumber: Int? = nil
    /// Soft per-entry counter — bumped every time we'd have created an
    /// issue but were blocked by the dedupe rule.  Useful for "you've hit
    /// this 12 times since the issue was opened" tracking.
    var dedupeHits: Int = 0

    init(rawText: String,
         normalizedText: String,
         action: String?,
         target: String?,
         targetLabel: String?,
         activeOverlay: String?,
         phase: String?,
         llmResolvedIntent: String? = nil,
         frequency: Int = 1) {
        self.id = UUID()
        self.timestamp = Date()
        self.lastSeenAt = Date()
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.action = action
        self.target = target
        self.targetLabel = targetLabel
        self.activeOverlay = activeOverlay
        self.phase = phase
        self.llmResolvedIntent = llmResolvedIntent
        self.frequency = frequency
    }
}

/// Bounded, JSON-persisted log of commands Jarvis didn't recognise.
/// Capped at 200 entries; newest first.
@Observable
@MainActor
final class UnmatchedCommandStore {
    private(set) var entries: [UnmatchedCommandEntry] = []
    private let fileURL: URL
    private let cap = 200

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory,
                  in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        fileURL = dir.appendingPathComponent("unmatched_commands.json")
        load()
    }

    func record(_ entry: UnmatchedCommandEntry) {
        // Deduplicate by normalizedText — increment frequency if seen before.
        if incrementFrequencyIfExists(normalizedText: entry.normalizedText) {
            return
        }
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        // Keep highest-frequency entries at the top.
        entries.sort { $0.frequency > $1.frequency }
        save()
    }

    /// If an entry with this normalized text already exists, increment its frequency.
    /// Returns true if found and incremented, false if it's a new entry.
    @discardableResult
    func incrementFrequencyIfExists(normalizedText: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.normalizedText == normalizedText }) else {
            return false
        }
        entries[idx].frequency += 1
        entries.sort { $0.frequency > $1.frequency }
        save()
        return true
    }

    /// Update the LLM-resolved intent label for an existing entry.
    func updateLLMResolution(_ intent: String, forNormalizedText text: String) {
        guard let idx = entries.firstIndex(where: { $0.normalizedText == text }) else { return }
        entries[idx].llmResolvedIntent = intent
        save()
    }

    /// Enrich an entry with the full diagnostic context.  Called from the
    /// FINAL unknown fallback in `JarvisController`, after every routing tier
    /// has declined.  No-op if the entry isn't present yet — caller should
    /// `record(...)` first.
    func enrich(normalizedText: String,
                currentApp: String?,
                matchedCandidate: String?,
                activeContext: String?,
                listeningMode: String?,
                lastIntent: String?,
                llmDecision: String?,
                androidConnected: Bool?,
                userExpectedAction: String?,
                appVersion: String?) {
        guard let idx = entries.firstIndex(where: { $0.normalizedText == normalizedText }) else { return }
        entries[idx].lastSeenAt          = Date()
        entries[idx].currentApp          = currentApp
        entries[idx].matchedCommandCandidate = matchedCandidate
        entries[idx].activeContext       = activeContext
        entries[idx].listeningMode       = listeningMode
        entries[idx].lastIntent          = lastIntent
        entries[idx].llmDecision         = llmDecision
        entries[idx].androidConnected    = androidConnected
        entries[idx].userExpectedAction  = userExpectedAction
        entries[idx].appVersion          = appVersion
        save()
    }

    /// Record that we attempted (or skipped) issue creation for this entry.
    /// Pass nil URL to record a dedupe hit; pass the new URL to set the linkage.
    func recordGitHubIssue(normalizedText: String,
                            url: String?,
                            number: Int?) {
        guard let idx = entries.firstIndex(where: { $0.normalizedText == normalizedText }) else { return }
        if let url {
            entries[idx].githubIssueURL = url
            entries[idx].githubIssueNumber = number
        } else {
            entries[idx].dedupeHits += 1
        }
        save()
    }

    /// True iff this normalised command already has a GitHub issue
    /// associated with it.  Drives dedupe in `GitHubIssueService`.
    func hasGitHubIssue(normalizedText: String) -> Bool {
        entries.contains(where: { $0.normalizedText == normalizedText
                                && $0.githubIssueURL != nil })
    }

    /// Latest entry for a given normalised command, if any.  Used by the
    /// issue service to read the enriched context block.
    func entry(normalizedText: String) -> UnmatchedCommandEntry? {
        entries.first(where: { $0.normalizedText == normalizedText })
    }

    func recent(limit: Int = 20) -> [UnmatchedCommandEntry] {
        Array(entries.prefix(limit))
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([UnmatchedCommandEntry].self,
                                             from: data)) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
