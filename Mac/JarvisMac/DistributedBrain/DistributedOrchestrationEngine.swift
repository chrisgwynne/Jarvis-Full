import Foundation

// MARK: - DistributedOrchestrationEngine

/// Decides which device handles each conversational turn, how verbosely, and whether
/// execution should be delegated to a Windows sidecar.
///
/// Architecture law: Mac ALWAYS responds. Windows is assigned rendering/execution
/// duties only — never autonomous decision-making authority.
@MainActor
final class DistributedOrchestrationEngine {

    static let shared = DistributedOrchestrationEngine()

    // MARK: - Config

    static let macDeviceId = "mac"

    private let deepWorkApps: Set<String> = [
        "xcode", "code", "cursor", "pycharm", "intellij", "goland", "clion",
        "webstorm", "rider", "android studio", "visual studio", "vim", "nvim", "neovim"
    ]

    // MARK: - Decision

    /// Produces an orchestration decision: who responds, how verbosely, what to delegate.
    func decide(
        transcript: String,
        sourceDeviceId: String,
        intentLabel: String?,
        presence: PresenceSnapshot?,
        isMacListening: Bool,
        isMacSpeaking: Bool
    ) -> OrchestrationDecision {
        // Mac always responds — it is the brain.
        let deviceId = Self.macDeviceId

        // Verbosity reduction: when Windows user is in deep coding flow, be brief.
        let verbosity = computeVerbosity(presence: presence, intentLabel: intentLabel)

        // Overlay delegation: show result on Windows when user is focused there.
        let showOverlay = shouldShowOverlayOnWindows(presence: presence)

        // Speak on Mac unless Windows is the exclusive surface right now.
        let shouldSpeak = !isMacSpeaking

        let reason = buildReason(presence: presence, verbosity: verbosity, showOverlay: showOverlay)

        return OrchestrationDecision(
            respondingDeviceId: deviceId,
            verbosity: verbosity,
            shouldSpeak: shouldSpeak,
            shouldShowOverlay: showOverlay,
            reason: reason
        )
    }

    // MARK: - Execution delegation

    /// Returns true when the intent is better executed on a Windows sidecar
    /// (e.g. clicking a browser element visible on Windows, not Mac).
    func shouldDelegateExecution(intentLabel: String?, presence: PresenceSnapshot?) -> Bool {
        guard let label = intentLabel else { return false }
        // Navigation/click intents that require Windows browser context
        let windowsIntents = ["openURL", "browserClick", "clipboardRead", "ocrCapture"]
        guard windowsIntents.contains(where: { label.lowercased().contains($0.lowercased()) }) else {
            return false
        }
        // Only delegate when Windows user is present and browsing
        guard let snap = presence else { return false }
        return snap.isUserPresent && (snap.attentionLevel == .browsing || snap.attentionLevel == .working)
    }

    // MARK: - Private

    private func computeVerbosity(presence: PresenceSnapshot?, intentLabel: String?) -> OrchestrationDecision.Verbosity {
        guard let snap = presence, snap.isUserPresent else { return .full }
        switch snap.attentionLevel {
        case .codingFlow:
            return .brief
        case .meeting:
            return .silent
        case .idle:
            return .full
        default:
            return .full
        }
    }

    private func shouldShowOverlayOnWindows(presence: PresenceSnapshot?) -> Bool {
        guard let snap = presence, snap.isUserPresent else { return false }
        return snap.attentionLevel == .working || snap.attentionLevel == .browsing
    }

    private func buildReason(
        presence: PresenceSnapshot?,
        verbosity: OrchestrationDecision.Verbosity,
        showOverlay: Bool
    ) -> String {
        guard let snap = presence else { return "mac-only session" }
        var parts: [String] = ["windows=\(snap.attentionLevel.rawValue)"]
        parts.append("verbosity=\(verbosity.rawValue)")
        if showOverlay { parts.append("overlay→windows") }
        return parts.joined(separator: " ")
    }
}
