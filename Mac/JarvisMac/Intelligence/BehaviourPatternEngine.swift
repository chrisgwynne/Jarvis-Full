import Foundation
import os

// MARK: - BehaviourPattern

struct BehaviourPattern: Identifiable, Codable {
    let id: String
    var intentLabel: String
    var hourOfDay: Int?            // nil = any hour
    var dayOfWeek: Int?            // nil = any day (1=Sunday, 7=Saturday)
    var contextApp: String?        // nil = any app
    var occurrenceCount: Int
    var lastSeenAt: Date
    var confidence: Double         // frequency-weighted confidence

    var isStrong: Bool { occurrenceCount >= 5 && confidence >= 0.60 }
    var isWeak: Bool { occurrenceCount < 3 }
}

// MARK: - BehaviourPatternEngine

/// Learns the user's recurring intent patterns from successful command routing.
///
/// Uses a simple frequency-based model: commands that occur ≥5 times in the
/// same time/app context get a pattern entry. The `PredictiveSuggestionEngine`
/// reads these patterns to surface contextual suggestions.
///
/// **Privacy**: patterns store intent labels and context metadata only — never
/// raw transcripts or personal content.
@MainActor
final class BehaviourPatternEngine {

    static let shared = BehaviourPatternEngine()
    private let log = Logger(subsystem: "com.jarvis", category: "intelligence.patterns")

    // MARK: - State

    private(set) var patterns: [BehaviourPattern] = []
    private let maxPatterns = 200

    // MARK: - Persistence

    private var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac")
            .appendingPathComponent("behaviour_patterns.json")
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([BehaviourPattern].self, from: data)
        else { return }
        patterns = loaded
        log.debug("Loaded \(loaded.count) behaviour patterns")
    }

    private func saveToDisk() {
        Task.detached(priority: .utility) { [patterns = self.patterns, url = fileURL] in
            guard let data = try? JSONEncoder().encode(patterns) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Recording

    /// Record a successfully executed intent. Call from JarvisController after execute().
    func recordIntent(_ intentLabel: String, inApp app: String? = nil) {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        let key = patternKey(intent: intentLabel, hour: hour, weekday: weekday, app: app)

        if let idx = patterns.firstIndex(where: { $0.id == key }) {
            patterns[idx].occurrenceCount += 1
            patterns[idx].lastSeenAt = now
            patterns[idx].confidence = min(1.0, Double(patterns[idx].occurrenceCount) / 20.0)
        } else {
            let pattern = BehaviourPattern(
                id: key,
                intentLabel: intentLabel,
                hourOfDay: hour,
                dayOfWeek: weekday,
                contextApp: app,
                occurrenceCount: 1,
                lastSeenAt: now,
                confidence: 0.05
            )
            patterns.append(pattern)
            enforceCap()
        }
        saveToDisk()
    }

    // MARK: - Query

    /// Patterns likely for the current time/app context. Strong patterns only.
    func currentContextPatterns(app: String? = nil, limit: Int = 5) -> [BehaviourPattern] {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        return patterns
            .filter { p in
                guard p.isStrong else { return false }
                let hourMatch  = p.hourOfDay == nil || abs((p.hourOfDay ?? hour) - hour) <= 1
                let dayMatch   = p.dayOfWeek == nil || p.dayOfWeek == weekday
                let appMatch   = p.contextApp == nil || p.contextApp == app
                return hourMatch && dayMatch && appMatch
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { $0 }
    }

    /// All strong patterns (frequency ≥ 5).
    var strongPatterns: [BehaviourPattern] {
        patterns.filter { $0.isStrong }.sorted { $0.confidence > $1.confidence }
    }

    /// Most frequent intents regardless of context.
    func topIntents(limit: Int = 10) -> [(intent: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in patterns { counts[p.intentLabel, default: 0] += p.occurrenceCount }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    // MARK: - Internal

    private func patternKey(intent: String, hour: Int, weekday: Int, app: String?) -> String {
        // Bucket hours into 3-hour windows for generalization
        let bucket = (hour / 3) * 3
        let appPart = app.map { "-\($0)" } ?? ""
        return "\(intent)-h\(bucket)-d\(weekday)\(appPart)"
    }

    private func enforceCap() {
        guard patterns.count > maxPatterns else { return }
        patterns = patterns
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
            .prefix(maxPatterns)
            .map { $0 }
    }

    var diagnosticSummary: String {
        "patterns=\(patterns.count) strong=\(strongPatterns.count)"
    }
}
