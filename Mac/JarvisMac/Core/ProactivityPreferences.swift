import Foundation

/// Persists user feedback about proactivity signals so the engine can
/// learn which sources/categories are welcome vs noisy.
///
/// Stored in UserDefaults under "ProactivityPreferences".
/// Format is simple JSON-encoded structs — no Core Data needed.
struct ProactivityPreferences: Codable {

    // MARK: - Suppressed combinations (source + category → never speak)

    /// Set of "source::category" keys that have been suppressed by the user.
    var suppressedKeys: Set<String> = []

    // MARK: - Boosted combinations (user wants to always hear)

    var boostedKeys: Set<String> = []

    // MARK: - Feedback counters (for diagnostics / future ML)

    /// Positive feedback counts per "source::category".
    var positiveCount: [String: Int] = [:]
    /// Negative feedback counts per "source::category".
    var negativeCount: [String: Int] = [:]

    // MARK: - Key helpers

    private func key(_ source: SignalSource, _ category: String) -> String {
        category.isEmpty ? source.rawValue : "\(source.rawValue)::\(category)"
    }

    // MARK: - Public API

    mutating func suppress(source: SignalSource, category: String) {
        suppressedKeys.insert(key(source, category))
        boostedKeys.remove(key(source, category))
        save()
    }

    mutating func boost(source: SignalSource, category: String) {
        boostedKeys.insert(key(source, category))
        suppressedKeys.remove(key(source, category))
        save()
    }

    func isSuppressed(source: SignalSource, category: String) -> Bool {
        // Check specific key first, then source-level suppression.
        suppressedKeys.contains(key(source, category))
            || (!category.isEmpty && suppressedKeys.contains(source.rawValue))
    }

    func isBoosted(source: SignalSource, category: String) -> Bool {
        boostedKeys.contains(key(source, category))
            || boostedKeys.contains(source.rawValue)
    }

    mutating func recordPositive(source: SignalSource, category: String) {
        let k = key(source, category)
        positiveCount[k, default: 0] += 1
        save()
    }

    mutating func recordNegative(source: SignalSource, category: String) {
        let k = key(source, category)
        negativeCount[k, default: 0] += 1
        // Auto-suppress if negative feedback accumulates (3+ times).
        if (negativeCount[k] ?? 0) >= 3 {
            suppress(source: source, category: category)
        } else {
            save()
        }
    }

    // MARK: - Persistence

    private static let udKey = "ProactivityPreferences"

    private func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.udKey)
        }
    }

    static func load() -> ProactivityPreferences {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let prefs = try? JSONDecoder().decode(ProactivityPreferences.self, from: data) else {
            return ProactivityPreferences()
        }
        return prefs
    }
}
