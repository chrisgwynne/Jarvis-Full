import Foundation
import os

// MARK: - EpisodeBrainBridge

/// Drives EpisodeStore from ambient SystemBus events.
///
/// - App focus changes open or annotate the active episode with the frontmost app.
/// - Conversation starts hint the episode with "voice" as a topic.
/// - Intent resolution stamps the episode with a topic derived from the intent label.
///
/// All handlers are lightweight MainActor callbacks — no async, no network, no disk.
@MainActor
final class EpisodeBrainBridge {

    private var tokens: [SystemBus.SubscriptionToken] = []
    private let log = Logger(subsystem: "com.jarvis", category: "brain.episode-bridge")

    // MARK: - Lifecycle

    func start() {
        tokens.append(
            SystemBus.shared.subscribe(AppFocusChangedEvent.self) { [weak self] event in
                self?.handleAppFocus(event)
            }
        )
        tokens.append(
            SystemBus.shared.subscribe(ConversationStartedEvent.self) { [weak self] event in
                self?.handleConversationStarted(event)
            }
        )
        tokens.append(
            SystemBus.shared.subscribe(IntentResolvedEvent.self) { [weak self] event in
                self?.handleIntentResolved(event)
            }
        )
        log.info("brain.episode-bridge: started")
    }

    func stop() {
        tokens.forEach { SystemBus.shared.unsubscribe($0) }
        tokens.removeAll()
    }

    // MARK: - Handlers

    private func handleAppFocus(_ event: AppFocusChangedEvent) {
        guard !event.activeApp.isEmpty else { return }
        EpisodeStore.shared.maybeAutoStart(appName: event.activeApp)
    }

    private func handleConversationStarted(_ event: ConversationStartedEvent) {
        EpisodeStore.shared.maybeAutoStart(topicHint: "voice")
    }

    private func handleIntentResolved(_ event: IntentResolvedEvent) {
        let topic = topicFromIntentLabel(event.intentLabel)
        guard !topic.isEmpty else { return }
        EpisodeStore.shared.recordTopic(topic)
    }

    // MARK: - Helpers

    /// Converts a camelCase intent label to a readable topic keyword.
    /// "homeTurnOn" → "home", "spotify" → "spotify", "calendar" → "calendar".
    private func topicFromIntentLabel(_ label: String) -> String {
        guard !label.isEmpty else { return "" }
        // Strip "unknown", "discard" noise
        let lower = label.lowercased()
        let skip = ["unknown", "discard", "none", "followup"]
        if skip.contains(where: { lower.hasPrefix($0) }) { return "" }

        // Extract leading word from camelCase (e.g. "homeTurnOn" → "home")
        var result = ""
        for ch in label {
            if ch.isUppercase, !result.isEmpty { break }
            result.append(ch.lowercased())
        }
        return result.count > 2 ? result : ""
    }
}
