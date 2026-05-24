import Foundation

// MARK: - ActionResult

/// The outcome of executing an intent — drives what Jarvis says (if anything).
enum ActionResult {
    case success
    case failure(String)
    case needsClarification(String)
    case destructive(description: String)
    case pending
}

// MARK: - ActionPolicy

/// Controls when Jarvis speaks about a command execution.
///
/// Default: silent on success so commands feel like side-effects of
/// conversation rather than the primary focus. Speech on failure,
/// clarification, or destructive actions ensures the user is never
/// silently confused.
struct ActionPolicy {
    /// Suppress "done" / "OK" / confirmation TTS on successful silent execution.
    var silentSuccess: Bool = true
    /// Speak when a command fails (error feedback).
    var speakOnFailure: Bool = true
    /// Speak clarifying questions ("which light did you mean?").
    var speakOnClarification: Bool = true
    /// Speak before executing irreversible/sensitive actions.
    var speakOnDestructiveAction: Bool = true
    /// Speak when the user explicitly requested confirmation ("did that work?").
    var speakOnUserRequestedConfirmation: Bool = true

    // MARK: - Classified intents

    /// Intent labels whose results matter conversationally (answer-type intents).
    static let resultsMatterLabels: Set<String> = [
        "readLatestEmail", "checkEmail", "searchNotes", "searchEmail",
        "getCurrentWeather", "getWeatherForecast", "getCalendarEvents",
        "queryMemory", "getTasks", "getGitHubNotifications",
        "brainSummaryToday", "brainSummaryWeek", "whatAmIWorkingOn",
        "whatCanYouSee", "describeCamera", "searchReddit"
    ]

    /// Intent labels considered destructive — always confirm verbally.
    static let destructiveLabels: Set<String> = [
        "deleteFile", "clearMemory", "factoryReset", "deleteNote",
        "clearConversation", "deleteTask", "shutDown", "restart",
        "clearBrainMemory", "resetCalibration"
    ]

    // MARK: - Decision

    /// Returns true when Jarvis should speak after executing the intent.
    func shouldSpeak(
        intentLabel: String,
        result: ActionResult,
        userRequestedConfirmation: Bool = false
    ) -> Bool {
        switch result {
        case .success:
            if userRequestedConfirmation && speakOnUserRequestedConfirmation { return true }
            if Self.resultsMatterLabels.contains(intentLabel) { return true }
            return !silentSuccess

        case .failure:
            return speakOnFailure

        case .needsClarification:
            return speakOnClarification

        case .destructive:
            return speakOnDestructiveAction

        case .pending:
            return false
        }
    }

    func isDestructive(_ intentLabel: String) -> Bool {
        Self.destructiveLabels.contains(intentLabel)
    }

    // MARK: - Presets

    /// Silent on success, speak on everything else. Default for conversational mode.
    static let `default` = ActionPolicy()

    /// Always speaks — old command-executor behaviour.
    static let verbose = ActionPolicy(silentSuccess: false)

    /// Speak only on destructive actions and required clarification.
    static let minimal = ActionPolicy(silentSuccess: true, speakOnFailure: false)
}
