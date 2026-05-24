import Foundation

/// Persistent, searchable activity timeline. Stores a bounded ring of
/// ActivityEvents in memory and flushes to JSON on disk. No raw media.
@Observable
@MainActor
final class ActivityTimelineStore {

    private(set) var events: [ActivityEvent] = []

    private let maxInMemory = 500
    private let persistURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        persistURL = dir.appendingPathComponent("activity_timeline.json")
        loadFromDisk()
    }

    // MARK: - Recording

    func record(_ event: ActivityEvent) {
        events.append(event)
        trim()
        scheduleSave()
    }

    func record(kind: ActivityEventKind,
                title: String,
                detail: String? = nil,
                appName: String? = nil) {
        record(ActivityEvent(kind: kind, title: title, detail: detail, appName: appName))
    }

    // MARK: - Querying

    func today() -> [ActivityEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDateInToday($0.timestamp) }
    }

    func recent(limit: Int = 50) -> [ActivityEvent] {
        Array(events.suffix(limit))
    }

    func search(_ query: String) -> [ActivityEvent] {
        let q = query.lowercased()
        return events.filter {
            $0.title.lowercased().contains(q)
            || ($0.detail?.lowercased().contains(q) ?? false)
            || ($0.appName?.lowercased().contains(q) ?? false)
        }
    }

    func events(for kind: ActivityEventKind) -> [ActivityEvent] {
        events.filter { $0.kind == kind }
    }

    // MARK: - Grouping for UI

    /// Returns events grouped by hour label e.g. "2:00 PM", most-recent first.
    func groupedByHour(from source: [ActivityEvent]? = nil) -> [(label: String, events: [ActivityEvent])] {
        let list = (source ?? recent(limit: 100)).reversed()
        var groups: [(label: String, events: [ActivityEvent])] = []
        var seen: [String: Int] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"

        for event in list {
            let label = hourLabel(for: event.timestamp)
            if let idx = seen[label] {
                groups[idx].events.append(event)
            } else {
                seen[label] = groups.count
                groups.append((label: label, events: [event]))
            }
        }
        return groups
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        // Persist last 200 events only
        let toSave = Array(events.suffix(200))
        if let data = try? encoder.encode(toSave) {
            try? data.write(to: persistURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: persistURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ActivityEvent].self, from: data) {
            events = loaded
        }
    }

    private func trim() {
        if events.count > maxInMemory {
            events.removeFirst(events.count - maxInMemory)
        }
    }

    private func hourLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return fmt.string(from: date)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h a"
        return fmt.string(from: date)
    }
}
