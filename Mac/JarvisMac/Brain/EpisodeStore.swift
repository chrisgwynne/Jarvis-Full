import Foundation
import os

// MARK: - EpisodeStore

/// Groups related memories, commands, and entities into time-bounded episodes.
///
/// An episode is automatically opened when a significant activity burst begins
/// (new active app, topic shift, or >30 min inactivity gap). Episodes are
/// closed when the burst ends or after a configurable idle timeout.
///
/// Users can also name episodes explicitly: "remember this session as the
/// hand-tracking debugging session".
///
/// Queries:
/// - "What did we do yesterday?" → `episodesOnDate()`
/// - "What happened during the GitHub audit?" → `search(query:)`
/// - "Summarise this week's work" → `weekSummary()`
@MainActor
final class EpisodeStore {

    static let shared = EpisodeStore()

    // MARK: - Dependencies

    private var db: JarvisDatabase?
    private let log = Logger(subsystem: "com.jarvis", category: "brain.episodes")

    // MARK: - In-memory state

    private(set) var episodes: [ConversationEpisode] = []
    private var activeEpisodeId: String?

    // MARK: - Auto-episode detection

    /// Gap in minutes after which a new episode is auto-started.
    private let idleGapMinutes: Double = 30

    // MARK: - Configuration

    func configure(db: JarvisDatabase) {
        self.db = db
        loadFromDisk()
    }

    // MARK: - Episode lifecycle

    /// Start a new episode. If one is already active, close it first.
    @discardableResult
    func beginEpisode(title: String,
                      type: EpisodeType = .general,
                      userInitiated: Bool = false) -> ConversationEpisode {
        // Close any open episode before starting a new one
        if let activeId = activeEpisodeId {
            endEpisode(activeId, summary: "")
        }
        var ep = ConversationEpisode(title: title, startedAt: Date())
        ep.episodeType   = type
        ep.userInitiated = userInitiated
        episodes.append(ep)
        activeEpisodeId = ep.id
        persist(ep)
        SystemBus.shared.publish(BrainEpisodeStartedEvent(
            episodeId: ep.id, episodeTitle: ep.title))
        log.info("brain.episodes: started '\(ep.title)'")
        return ep
    }

    /// Close the episode and write its summary.
    func endEpisode(_ id: String, summary: String) {
        guard let idx = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[idx].endedAt = Date()
        episodes[idx].summary = summary
        if activeEpisodeId == id { activeEpisodeId = nil }
        persist(episodes[idx])
        SystemBus.shared.publish(BrainEpisodeEndedEvent(
            episodeId: id, memoryCount: episodes[idx].relatedMemoryIds.count))
        log.info("brain.episodes: ended '\(self.episodes[idx].title)' (\(self.episodes[idx].relatedMemoryIds.count) memories)")
    }

    /// Close the currently active episode, if any.
    func endActiveEpisode(summary: String = "") {
        guard let id = activeEpisodeId else { return }
        endEpisode(id, summary: summary)
    }

    // MARK: - Linking

    /// Associate a memory with the currently active episode (or specified episode).
    func linkMemory(_ memoryId: String, toEpisode episodeId: String? = nil) {
        let targetId = episodeId ?? activeEpisodeId
        guard let tid = targetId,
              let idx = episodes.firstIndex(where: { $0.id == tid }),
              !episodes[idx].relatedMemoryIds.contains(memoryId) else { return }
        episodes[idx].relatedMemoryIds.append(memoryId)
        persist(episodes[idx])
    }

    /// Associate an entity with the currently active episode (or specified episode).
    func linkEntity(_ entityId: String, toEpisode episodeId: String? = nil) {
        let targetId = episodeId ?? activeEpisodeId
        guard let tid = targetId,
              let idx = episodes.firstIndex(where: { $0.id == tid }),
              !episodes[idx].relatedEntityIds.contains(entityId) else { return }
        episodes[idx].relatedEntityIds.append(entityId)
        persist(episodes[idx])
    }

    /// Record a dominant app for the active episode.
    func recordApp(_ appName: String) {
        guard let id = activeEpisodeId,
              let idx = episodes.firstIndex(where: { $0.id == id }),
              !episodes[idx].dominantApps.contains(appName) else { return }
        episodes[idx].dominantApps.append(appName)
        persist(episodes[idx])
    }

    /// Record a dominant topic keyword for the active episode.
    func recordTopic(_ topic: String) {
        guard let id = activeEpisodeId,
              let idx = episodes.firstIndex(where: { $0.id == id }),
              !episodes[idx].dominantTopics.contains(topic) else { return }
        episodes[idx].dominantTopics.append(topic)
        persist(episodes[idx])
    }

    // MARK: - Auto-episode detection

    /// Call after each command/memory event to decide whether to auto-start a new episode.
    /// Uses a simple heuristic: open new episode if >30 min gap since last activity.
    func maybeAutoStart(topicHint: String? = nil, appName: String? = nil) {
        let now = Date()

        if let id = activeEpisodeId,
           let ep = episodes.first(where: { $0.id == id }) {
            // Active episode — record metadata
            if let app = appName { recordApp(app) }
            if let topic = topicHint { recordTopic(topic) }
            return
        }

        // No active episode — check if we need to open one
        let lastActivity = episodes
            .compactMap { $0.endedAt ?? ($0.id == activeEpisodeId ? Date() : nil) }
            .max() ?? Date.distantPast
        let gapMinutes = now.timeIntervalSince(lastActivity) / 60

        if gapMinutes > idleGapMinutes || episodes.isEmpty {
            let title = generateTitle(app: appName, topic: topicHint, date: now)
            beginEpisode(title: title, type: .general)
            if let app   = appName    { recordApp(app)   }
            if let topic = topicHint  { recordTopic(topic) }
        }
    }

    // MARK: - Queries

    var activeEpisode: ConversationEpisode? {
        guard let id = activeEpisodeId else { return nil }
        return episodes.first { $0.id == id }
    }

    func recentEpisodes(limit: Int = 20) -> [ConversationEpisode] {
        episodes.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
    }

    func episodesOnDate(_ date: Date) -> [ConversationEpisode] {
        let cal = Calendar.current
        return episodes.filter { cal.isDate($0.startedAt, inSameDayAs: date) }
    }

    func search(query: String) -> [ConversationEpisode] {
        let terms = query.lowercased().components(separatedBy: " ").filter { $0.count > 2 }
        guard !terms.isEmpty else { return recentEpisodes() }
        return episodes.filter { ep in
            let text = "\(ep.title) \(ep.summary) \(ep.dominantTopics.joined(separator: " "))".lowercased()
            return terms.contains { text.contains($0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Summaries

    func todaysSummary() -> String {
        let today = episodesOnDate(Date())
        guard !today.isEmpty else { return "No episodes recorded today." }
        let count   = today.count
        let minutes = Int(today.compactMap { $0.durationMinutes }.reduce(0, +))
        let topics  = today.flatMap { $0.dominantTopics }.prefix(3).joined(separator: ", ")
        return "\(count) session\(count == 1 ? "" : "s") today (~\(minutes) min)\(topics.isEmpty ? "" : " — \(topics)")"
    }

    func weekSummary() -> String {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let recent = episodes.filter { $0.startedAt > sevenDaysAgo }
        let allTopics = recent.flatMap { $0.dominantTopics }
        let topTopic  = allTopics.sorted { a, b in
            allTopics.filter { $0 == a }.count > allTopics.filter { $0 == b }.count
        }.first ?? "various topics"
        return "\(recent.count) sessions this week — primarily \(topTopic)"
    }

    // MARK: - Private helpers

    private func generateTitle(app: String?, topic: String?, date: Date) -> String {
        let cal    = Calendar.current
        let hour   = cal.component(.hour, from: date)
        let period = hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening"
        if let topic = topic, !topic.isEmpty { return "\(period) — \(topic)" }
        if let app   = app,   !app.isEmpty   { return "\(period) — \(app)" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(period) session — \(formatter.string(from: date))"
    }

    private func loadFromDisk() {
        guard let db else { return }
        let rows = (try? db.recentBrainEpisodes(limit: 100)) ?? []
        episodes = rows.map { row -> ConversationEpisode in
            var ep = ConversationEpisode(title: row.title, startedAt: row.startedAt)
            ep.id              = row.id
            ep.endedAt         = row.endedAt
            ep.summary         = row.summary
            ep.relatedMemoryIds = parseJSON(row.memoryIdsJSON)
            ep.relatedEntityIds = parseJSON(row.entityIdsJSON)
            ep.dominantTopics   = parseJSON(row.topicsJSON)
            ep.dominantProjects = parseJSON(row.projectsJSON)
            ep.dominantApps     = parseJSON(row.appsJSON)
            ep.tags             = parseJSON(row.tagsJSON)
            ep.importance       = row.importance
            ep.episodeType      = EpisodeType(rawValue: row.episodeType) ?? .general
            ep.userInitiated    = row.userInitiated
            return ep
        }
        // Restore active episode (last episode without endedAt)
        activeEpisodeId = episodes.first(where: { $0.endedAt == nil })?.id
        log.info("brain.episodes: loaded \(self.episodes.count) episodes")
    }

    private func persist(_ ep: ConversationEpisode) {
        guard let db else { return }
        try? db.upsertBrainEpisode(
            id:            ep.id,
            title:         ep.title,
            startedAt:     ep.startedAt,
            endedAt:       ep.endedAt,
            summary:       ep.summary,
            memoryIdsJSON: jsonArray(ep.relatedMemoryIds),
            entityIdsJSON: jsonArray(ep.relatedEntityIds),
            topicsJSON:    jsonArray(ep.dominantTopics),
            projectsJSON:  jsonArray(ep.dominantProjects),
            appsJSON:      jsonArray(ep.dominantApps),
            tagsJSON:      jsonArray(ep.tags),
            importance:    ep.importance,
            episodeType:   ep.episodeType.rawValue,
            userInitiated: ep.userInitiated
        )
    }

    private func jsonArray(_ arr: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: arr), encoding: .utf8)) ?? "[]"
    }

    private func parseJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
