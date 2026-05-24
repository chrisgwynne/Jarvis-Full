import Foundation
import SwiftUI

// MARK: - SceneMemoryStore

/// Persistent, append-only log of visual scene events observed across all camera feeds.
/// Newest events are at the front of `events`. Capped at 1,000 entries.
/// Writes are debounced — a save is scheduled 3 seconds after the last `record()` call.
@MainActor @Observable final class SceneMemoryStore {

    // MARK: Singleton

    static let shared = SceneMemoryStore()

    // MARK: Observable state

    private(set) var events: [SceneEvent] = []          // newest first, max 1 000
    private(set) var todayEvents: [SceneEvent] = []     // today's subset (derived)

    // MARK: Private

    private let maxEvents = 1_000
    private let persistenceURL: URL
    private var saveTask: Task<Void, Never>?

    // MARK: Init

    private init() {
        // Resolve persistence path: ~/Library/Application Support/JarvisMac/scene_memory.json
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("JarvisMac", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        persistenceURL = appSupport.appendingPathComponent("scene_memory.json")
        load()
    }

    // MARK: Public API

    /// Append a new event to the log, trim if needed, refresh today's slice, and schedule a save.
    func record(_ event: SceneEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        refreshTodayEvents()
        scheduleDebouncedSave()
    }

    /// Returns the most recent events for a specific camera feed.
    func events(for cameraID: UUID, limit: Int = 20) -> [SceneEvent] {
        events
            .filter { $0.cameraFeedID == cameraID }
            .prefix(limit)
            .map { $0 }
    }

    /// Returns all events whose timestamp falls within `range` (inclusive).
    func events(in range: ClosedRange<Date>) -> [SceneEvent] {
        events.filter { range.contains($0.timestamp) }
    }

    /// Returns events since `date`, oldest first (suitable for chronological review).
    func eventsSince(_ date: Date) -> [SceneEvent] {
        events
            .filter { $0.timestamp >= date }
            .reversed()
    }

    /// Builds a brief natural-language summary of the most recent `limit` events,
    /// suitable for injection into an LLM context block.
    func recentSummary(limit: Int = 5) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let slice = events.prefix(limit)
        guard !slice.isEmpty else { return "No recent scene events." }

        return slice.map { event in
            let time = formatter.string(from: event.timestamp)
            return "\(time) – \(event.cameraName): \(event.description) (\(event.primaryThreat.label))"
        }.joined(separator: "\n")
    }

    /// Remove all stored events from memory and disk.
    func clearAll() {
        events = []
        todayEvents = []
        saveTask?.cancel()
        saveTask = nil
        try? FileManager.default.removeItem(at: persistenceURL)
    }

    // MARK: Convenience builder

    /// Build a `SceneEvent` from a snapshot of active tracked targets on a given camera.
    /// The description is human-readable and suitable for display in overlays or spoken aloud.
    func makeEvent(
        cameraFeedID: UUID,
        cameraName: String,
        targets: [TrackedTarget],
        motionIntensity: Float
    ) -> SceneEvent {
        // Count interesting classes
        let persons = targets.filter { $0.cls == .person && !$0.isGhost }.count
        let vehicles = targets.filter { $0.cls == .vehicle && !$0.isGhost }.count
        let faces = targets.filter { $0.cls == .face && !$0.isGhost }.count
        let other = targets.filter { ![.person, .vehicle, .face].contains($0.cls) && !$0.isGhost }.count

        // Build description
        var parts: [String] = []
        if persons > 0 { parts.append("\(persons) person\(persons == 1 ? "" : "s")") }
        if vehicles > 0 { parts.append("\(vehicles) vehicle\(vehicles == 1 ? "" : "s")") }
        if faces > 0 && persons == 0 { parts.append("\(faces) face\(faces == 1 ? "" : "s")") }
        if other > 0 { parts.append("\(other) other object\(other == 1 ? "" : "s")") }

        let description: String
        if parts.isEmpty {
            description = "No activity detected at \(cameraName)"
        } else {
            description = "\(parts.joined(separator: ", ")) detected at \(cameraName)"
        }

        // Collect unique detected classes
        let detectedClasses = Array(Set(targets.map { $0.cls }))

        // Primary threat = worst threat across all non-ghost targets
        let primaryThreat = targets
            .filter { !$0.isGhost }
            .map { $0.threatLevel }
            .max() ?? .normal

        return SceneEvent(
            cameraFeedID: cameraFeedID,
            cameraName: cameraName,
            detectedClasses: detectedClasses,
            primaryThreat: primaryThreat,
            description: description,
            motionIntensity: motionIntensity
        )
    }

    // MARK: Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Non-fatal — vision events are transient
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([SceneEvent].self, from: data)
            // Ensure newest-first ordering after load
            events.sort { $0.timestamp > $1.timestamp }
            // Trim to cap in case the file grew between versions
            if events.count > maxEvents {
                events = Array(events.prefix(maxEvents))
            }
            refreshTodayEvents()
        } catch {
            events = []
        }
    }

    /// Debounce saves: cancel any pending write task and schedule a new one 3 seconds out.
    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return  // Task was cancelled — a later call will reschedule
            }
            await self?.save()
        }
    }

    /// Rebuild todayEvents from the master list.
    private func refreshTodayEvents() {
        let calendar = Calendar.current
        todayEvents = events.filter { calendar.isDateInToday($0.timestamp) }
    }
}
