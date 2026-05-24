import Foundation

/// Returns safe (non-secret) user preferences for Android Jarvis personalisation.
/// NEVER includes API tokens, passwords, or raw Keychain values.
@MainActor
final class PreferenceContextProvider: BrainContextProviding {
    let category = "preferences"
    private weak var prefs: PreferencesStore?

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    func provide(query: String?, maxItems: Int) async -> BrainContextBlock? {
        guard let prefs else { return nil }
        let p = prefs.current

        var items: [BrainContextItem] = []

        if let name = p.userName, !name.isEmpty {
            items.append(BrainContextItem(key: "user_name", value: name, confidence: 1.0, source: "preferences"))
        }
        items.append(BrainContextItem(key: "assistant_name", value: p.assistantName, confidence: 1.0, source: "preferences"))

        // Timezone
        let tz = TimeZone.current.identifier
        items.append(BrainContextItem(key: "timezone", value: tz, confidence: 1.0, source: "system"))

        // HA base URL (no token — just tells Android whether HA is configured)
        if let haURL = p.smartHomeBaseURL, !haURL.isEmpty {
            items.append(BrainContextItem(key: "ha_configured", value: "true", confidence: 1.0, source: "preferences"))
            items.append(BrainContextItem(key: "ha_base_url", value: haURL, confidence: 1.0, source: "preferences"))
        }

        guard !items.isEmpty else { return nil }
        return BrainContextBlock(category: category, label: "Preferences", items: items)
    }
}
