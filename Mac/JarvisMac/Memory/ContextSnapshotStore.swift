import Foundation

/// Persists lightweight snapshots of assistant state to the `context_snapshots`
/// table after each completed command. Provides the "what was I doing earlier"
/// and "show recent activity" queries.
///
/// Snapshots are fire-and-forget: failures are logged but never surface to the UI.
/// All DB work runs on a private serial queue.
final class ContextSnapshotStore {

    private let db: JarvisDatabase
    private let queue = DispatchQueue(label: "com.jarvis.mac.snapshots", qos: .utility)

    init(db: JarvisDatabase) {
        self.db = db
    }

    // MARK: - Write

    /// Save a snapshot. Called from JarvisController after every completed command.
    func save(phase: String,
              activeApp: String = "",
              lastIntent: String,
              lastAction: String = "",
              lastResponse: String,
              sessionId: String) {
        guard !lastResponse.isEmpty || !lastIntent.isEmpty else { return }
        queue.async { [db] in
            do {
                let summary = Self.buildSummary(
                    lastIntent: lastIntent,
                    lastResponse: lastResponse,
                    activeApp: activeApp
                )
                try db.insertSnapshotFull(
                    phase: phase,
                    activeApp: activeApp,
                    summary: summary,
                    lastIntent: lastIntent,
                    lastAction: lastAction,
                    lastResponse: lastResponse,
                    sessionId: sessionId
                )
                Log.memory.debug("snapshot saved: \(lastResponse.prefix(60))")
            } catch {
                Log.memory.error("snapshot save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Read

    /// Recent snapshots, newest first.
    func recent(limit: Int = 10) async -> [SnapshotRow] {
        await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.recentSnapshotsFull(limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    /// Current-session snapshots, newest first.
    func currentSession(sessionId: String, limit: Int = 20) async -> [SnapshotRow] {
        await withCheckedContinuation { cont in
            queue.async { [db] in
                let rows = (try? db.snapshotsForSession(sessionId: sessionId, limit: limit)) ?? []
                cont.resume(returning: rows)
            }
        }
    }

    /// Natural-language activity summary for TTS ("what was I doing earlier").
    func activitySummary(limit: Int = 5) async -> String {
        let rows = await recent(limit: limit)
        guard !rows.isEmpty else {
            return "I don't have any recent activity recorded yet."
        }
        let lines: [String] = rows.prefix(limit).compactMap { row in
            let ago = Self.relativeTime(row.ts)
            if !row.lastResponse.isEmpty {
                return "\(ago): \(row.lastResponse.prefix(100))"
            } else if !row.lastIntent.isEmpty {
                return "\(ago): \(row.lastIntent)"
            }
            return nil
        }
        guard !lines.isEmpty else { return "I don't have any recent activity recorded yet." }
        return "Here's what I've been up to:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5  { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    private static func buildSummary(lastIntent: String,
                                     lastResponse: String,
                                     activeApp: String) -> String {
        var parts: [String] = []
        if !lastResponse.isEmpty { parts.append(String(lastResponse.prefix(120))) }
        else if !lastIntent.isEmpty { parts.append(lastIntent) }
        if !activeApp.isEmpty { parts.append("in \(activeApp)") }
        return parts.joined(separator: " — ")
    }
}
