import Foundation

// MARK: - GlobalPresenceAggregator

/// Ingests real-time presence data from all connected surfaces (Windows, Android, etc.).
/// Applies debouncing (1 s per device), privacy filtering, and bounded retention.
/// Mac's own presence is NOT stored here — it is derived from AmbientWorldState.
@MainActor
final class GlobalPresenceAggregator {

    static let shared = GlobalPresenceAggregator()

    // MARK: - Config

    private static let maxSnapshots = 10
    private static let debounceInterval: TimeInterval = 1.0
    private static let retentionSeconds: TimeInterval = 300   // 5 min

    // MARK: - State

    private(set) var snapshots: [String: PresenceSnapshot] = [:]  // deviceId → latest
    private var lastUpdateTime: [String: Date] = [:]
    private var blockedDeviceIds: Set<String> = []

    // MARK: - Update

    /// Ingests a presence snapshot. Returns false if debounced or blocked.
    @discardableResult
    func update(_ snapshot: PresenceSnapshot) -> Bool {
        guard !blockedDeviceIds.contains(snapshot.deviceId) else { return false }

        let now = Date()
        if let last = lastUpdateTime[snapshot.deviceId],
           now.timeIntervalSince(last) < Self.debounceInterval {
            return false
        }
        lastUpdateTime[snapshot.deviceId] = now

        // Privacy filter: strip OCR summary for password-manager / incognito contexts.
        var safe = snapshot
        if let ocrSummary = snapshot.ocrSummary {
            let filter = PrivacyFilter()
            if filter.isBlocked(
                bundleID: "", appName: snapshot.foregroundApp ?? "", windowTitle: ocrSummary
            ) {
                safe = PresenceSnapshot(
                    deviceId: snapshot.deviceId,
                    timestamp: snapshot.timestamp,
                    foregroundApp: snapshot.foregroundApp,
                    foregroundWindowTitle: nil,
                    browserURL: snapshot.browserURL,
                    ocrSummary: nil,
                    isUserPresent: snapshot.isUserPresent,
                    attentionLevel: snapshot.attentionLevel,
                    activeCodingFile: snapshot.activeCodingFile,
                    activeCodingLanguage: snapshot.activeCodingLanguage
                )
            }
        }

        snapshots[snapshot.deviceId] = safe

        // Evict stale snapshots when over cap
        pruneIfNeeded(now: now)
        return true
    }

    // MARK: - Query

    func latestPresence(forDevice deviceId: String) -> PresenceSnapshot? {
        guard let snap = snapshots[deviceId] else { return nil }
        guard Date().timeIntervalSince(snap.timestamp) < Self.retentionSeconds else {
            snapshots.removeValue(forKey: deviceId)
            return nil
        }
        return snap
    }

    var allPresence: [PresenceSnapshot] {
        let now = Date()
        return snapshots.values.filter {
            now.timeIntervalSince($0.timestamp) < Self.retentionSeconds
        }.sorted { $0.timestamp > $1.timestamp }
    }

    var windowsPresence: PresenceSnapshot? {
        allPresence.first { $0.deviceId.lowercased().contains("windows") || $0.deviceId == "windows" }
    }

    var anyDeviceHasUserPresent: Bool {
        allPresence.contains { $0.isUserPresent }
    }

    // MARK: - Context block

    func contextBlock() -> String {
        let snaps = allPresence.prefix(3)
        guard !snaps.isEmpty else { return "" }
        var lines = ["[SIDECAR PRESENCE]"]
        for snap in snaps {
            var parts: [String] = ["\(snap.deviceId): \(snap.attentionLevel.rawValue)"]
            if let app = snap.foregroundApp { parts.append("app=\(app)") }
            if let file = snap.activeCodingFile { parts.append("file=\(file)") }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Privacy control

    func blockDevice(_ deviceId: String) { blockedDeviceIds.insert(deviceId) }
    func unblockDevice(_ deviceId: String) { blockedDeviceIds.remove(deviceId) }

    // MARK: - Private

    private func pruneIfNeeded(now: Date) {
        // Remove stale by age
        snapshots = snapshots.filter { now.timeIntervalSince($0.value.timestamp) < Self.retentionSeconds }
        // Keep only most recent N if over cap
        if snapshots.count > Self.maxSnapshots {
            let sorted = snapshots.sorted { $0.value.timestamp > $1.value.timestamp }
            snapshots = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxSnapshots).map { ($0.key, $0.value) })
        }
    }
}
