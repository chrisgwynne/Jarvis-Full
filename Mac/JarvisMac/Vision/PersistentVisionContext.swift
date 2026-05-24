import Foundation

// MARK: - UserPresenceKind

/// Whether the user is physically at their desk. Distinct from CameraModels.PresenceState
/// (which counts people) — this is the coordinator-level "is Chris here?" state.
enum UserPresenceKind: String, Codable {
    case present       // user is at desk
    case away          // desk is unoccupied
    case unknown       // camera unavailable or uncertain
}

// MARK: - PersistentVisionContext

/// Lightweight persistence layer for vision-derived user state.
///
/// Rather than recomputing presence from camera frames on every orchestrator query,
/// this class maintains a running snapshot updated asynchronously by
/// `SceneChangeDetector`. The orchestrator reads synchronously — zero latency.
///
/// Uses the existing `AttentionState` enum from `Attention/AttentionState.swift`.
@MainActor
final class PersistentVisionContext {

    static let shared = PersistentVisionContext()

    // MARK: - State

    private(set) var presenceKind: UserPresenceKind = .unknown
    private(set) var attentionState: AttentionState = .unknown
    private(set) var isDeskOccupied: Bool = false
    private(set) var lastUpdatedAt: Date?
    private(set) var confidenceScore: Double = 0

    // MARK: - Session tracking

    private(set) var presenceSessionStart: Date?

    // MARK: - Update API (called by SceneChangeDetector or JarvisController)

    func updatePresence(_ kind: UserPresenceKind, confidence: Double) {
        let wasPresent = presenceKind == .present
        presenceKind = kind
        confidenceScore = confidence
        lastUpdatedAt = Date()

        if kind == .present && !wasPresent {
            presenceSessionStart = Date()
            SystemBus.shared.publish(UserPresenceDetectedEvent())
        } else if kind == .away && wasPresent {
            presenceSessionStart = nil
            SystemBus.shared.publish(UserAwayDetectedEvent())
        }

        isDeskOccupied = (kind == .present && confidence >= 0.55)
        saveToDisk()
    }

    func updateAttention(_ state: AttentionState) {
        attentionState = state
        lastUpdatedAt = Date()
    }

    func markCameraUnavailable() {
        presenceKind = .unknown
        attentionState = .unknown
        confidenceScore = 0
    }

    // MARK: - Derived queries

    var continuousPresenceDuration: Double {
        guard let start = presenceSessionStart else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var isFresh: Bool {
        guard let updated = lastUpdatedAt else { return false }
        return Date().timeIntervalSince(updated) < 90
    }

    var oneLiner: String {
        let p = presenceKind.rawValue
        let a = attentionState.rawValue
        let age = lastUpdatedAt.map { Int(Date().timeIntervalSince($0)) }.map { "\($0)s ago" } ?? "never"
        return "presence=\(p) attention=\(a) confidence=\(Int(confidenceScore * 100))% updated=\(age)"
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var presence: String
        var isDeskOccupied: Bool
        var lastUpdatedAt: Date
        var confidence: Double
    }

    private var snapshotURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JarvisMac")
            .appendingPathComponent("vision_context.json")
    }

    private func saveToDisk() {
        guard let url = snapshotURL,
              let data = try? JSONEncoder().encode(Snapshot(
                presence: presenceKind.rawValue,
                isDeskOccupied: isDeskOccupied,
                lastUpdatedAt: lastUpdatedAt ?? Date(),
                confidence: confidenceScore
              ))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadFromDisk() {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snap.lastUpdatedAt) < 3600
        else { return }
        presenceKind    = UserPresenceKind(rawValue: snap.presence) ?? .unknown
        isDeskOccupied  = snap.isDeskOccupied
        lastUpdatedAt   = snap.lastUpdatedAt
        confidenceScore = snap.confidence
    }
}

// MARK: - System Events

struct UserPresenceDetectedEvent: SystemEvent {
    let id = UUID()
    let timestamp = Date()
    var source: SystemEventSource    { .ambient }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .normal }
    var correlationID: UUID?          { nil }
}

struct UserAwayDetectedEvent: SystemEvent {
    let id = UUID()
    let timestamp = Date()
    var source: SystemEventSource    { .ambient }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .normal }
    var correlationID: UUID?          { nil }
}
