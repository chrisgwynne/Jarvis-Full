import Foundation

// MARK: - PredictiveSuggestion

struct PredictiveSuggestion: Identifiable {
    let id: UUID
    let intentLabel: String
    let suggestedPhrase: String
    let confidence: Double
    let reason: String

    /// True if confidence is high enough to announce proactively.
    var isActionable: Bool { confidence >= 0.70 }
}

// MARK: - PredictiveSuggestionEngine

/// Uses `BehaviourPatternEngine` to generate contextual suggestions.
///
/// **Anti-spam rules (hard-coded):**
/// - Never suggest the same intent more than once per 30 minutes.
/// - Only suggest when the user has been idle for ≥ 60 seconds.
/// - At most 1 proactive suggestion per 15-minute window.
/// - Never suggest during active conversation.
///
/// Suggestions are published as `ProactivitySignal` via `ProactivityOrchestrator`
/// so the full attention-policy chain is respected.
@MainActor
final class PredictiveSuggestionEngine {

    static let shared = PredictiveSuggestionEngine()

    // MARK: - Configuration

    var enabled: Bool = true
    var minIdleSecondsBeforeSuggestion: Double = 60
    var suggestionCooldownMinutes: Double = 15
    var maxSuggestionsPerHour: Int = 4

    // MARK: - State

    private var lastSuggestionTime: Date?
    private var recentlySuggestedIntents: [String: Date] = [:]
    private var suggestionsThisHour: Int = 0
    private var hourWindowStart: Date = Date()

    // MARK: - Public API

    /// Generate suggestions for the current context. Does not publish — caller
    /// decides whether to speak/show.
    func suggestionsForCurrentContext(
        activeApp: String? = nil,
        idleSeconds: Double = 0
    ) -> [PredictiveSuggestion] {
        guard enabled else { return [] }
        guard idleSeconds >= minIdleSecondsBeforeSuggestion else { return [] }
        guard !isInCooldown else { return [] }
        guard suggestionsThisHourCount < maxSuggestionsPerHour else { return [] }

        let patterns = BehaviourPatternEngine.shared.currentContextPatterns(app: activeApp, limit: 5)
        return patterns
            .filter { !wasSuggestedRecently($0.intentLabel) }
            .compactMap { buildSuggestion(from: $0) }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Emit the top suggestion as a proactivity signal if conditions are met.
    func emitTopSuggestionIfReady(idleSeconds: Double, activeApp: String? = nil) {
        guard enabled else { return }
        let suggestions = suggestionsForCurrentContext(activeApp: activeApp, idleSeconds: idleSeconds)
        guard let top = suggestions.first, top.isActionable else { return }

        recordSuggested(top.intentLabel)

        let signal = ProactivitySignal(
            source: .system,
            title: "Suggestion",
            body: top.suggestedPhrase,
            priority: .low,
            dedupeKey: "predict.\(top.intentLabel).\(Int(Date().timeIntervalSince1970 / 900))",
            spokenText: top.suggestedPhrase
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
    }

    // MARK: - Internal

    private var isInCooldown: Bool {
        guard let last = lastSuggestionTime else { return false }
        return Date().timeIntervalSince(last) < suggestionCooldownMinutes * 60
    }

    private var suggestionsThisHourCount: Int {
        if Date().timeIntervalSince(hourWindowStart) > 3600 {
            suggestionsThisHour = 0
            hourWindowStart = Date()
        }
        return suggestionsThisHour
    }

    private func wasSuggestedRecently(_ intentLabel: String) -> Bool {
        guard let last = recentlySuggestedIntents[intentLabel] else { return false }
        return Date().timeIntervalSince(last) < 30 * 60
    }

    private func recordSuggested(_ intentLabel: String) {
        lastSuggestionTime = Date()
        recentlySuggestedIntents[intentLabel] = Date()
        suggestionsThisHour += 1
    }

    private func buildSuggestion(from pattern: BehaviourPattern) -> PredictiveSuggestion? {
        guard let phrase = humanReadablePhrase(for: pattern.intentLabel) else { return nil }
        return PredictiveSuggestion(
            id: UUID(),
            intentLabel: pattern.intentLabel,
            suggestedPhrase: phrase,
            confidence: pattern.confidence,
            reason: "You often do this at this time in \(pattern.contextApp ?? "this context")."
        )
    }

    // MARK: - Phrase templates

    private static let phraseLookup: [String: String] = [
        "getCurrentWeather":       "Want the weather update?",
        "checkEmail":              "Want to check your email?",
        "getTasks":                "Want to review your tasks?",
        "showCalendarOverlay":     "Want to see today's calendar?",
        "getGitHubNotifications":  "Want to check GitHub notifications?",
        "checkShopify":            "Want the Shopify summary?",
        "showBrainOverlay":        "Want a memory summary?",
        "brainSummaryToday":       "Want today's brain summary?",
        "whatAmIWorkingOn":        "Want a focus summary?",
        "dailyBriefing":           "Want your daily briefing?",
        "getWeatherForecast":      "Want the forecast?",
    ]

    private func humanReadablePhrase(for intentLabel: String) -> String? {
        Self.phraseLookup[intentLabel]
    }

    var diagnosticSummary: String {
        "suggestions: cooldown=\(isInCooldown) thisHour=\(suggestionsThisHour)"
    }
}
