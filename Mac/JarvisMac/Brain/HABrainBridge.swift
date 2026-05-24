import Foundation
import os

// MARK: - HABrainBridge

/// Routes significant Home Assistant state changes into BrainMemoryStore.
///
/// Filtered domains (others are skipped to avoid memory noise):
/// - `lock`                — locked/unlocked changes (importance 0.65)
/// - `alarm_control_panel` — arm/disarm/triggered    (importance 0.70–0.95)
///
/// Privacy: HA state changes are personal home data; all memories use `.sensitive`
/// privacy level so they are never injected into LLM prompts.
///
/// Volume guard: identical entity+state pairs within 5 minutes are deduplicated
/// in-memory before reaching BrainMemoryStore's Jaccard gate.
@MainActor
final class HABrainBridge {

    private var tokens: [SystemBus.SubscriptionToken] = []
    private var recentKeys: [(key: String, at: Date)] = []
    private let dedupeWindowSeconds: Double = 300
    private let log = Logger(subsystem: "com.jarvis", category: "brain.ha-bridge")

    // MARK: - Lifecycle

    func start() {
        tokens.append(
            SystemBus.shared.subscribe(HAEntityChangedEvent.self) { [weak self] event in
                self?.handleEntityChanged(event)
            }
        )
        log.info("brain.ha-bridge: started")
    }

    func stop() {
        tokens.forEach { SystemBus.shared.unsubscribe($0) }
        tokens.removeAll()
    }

    // MARK: - Handler

    private func handleEntityChanged(_ event: HAEntityChangedEvent) {
        guard let (title, summary, importance) = classify(event) else { return }

        // Volume guard — skip duplicates within the dedupe window
        let key = "\(event.entityID):\(event.newState)"
        let now = Date()
        recentKeys.removeAll { now.timeIntervalSince($0.at) > dedupeWindowSeconds }
        guard !recentKeys.contains(where: { $0.key == key }) else { return }
        recentKeys.append((key: key, at: now))

        var candidate = MemoryCandidate(
            type: .personalFact,
            tier: .projectMemory,
            title: title,
            summary: summary,
            rawText: summary,
            confidence: 0.85,
            tags: ["home-assistant", event.domain],
            createdAt: event.timestamp
        )
        candidate.source       = .homeAssistant
        candidate.importance   = importance
        candidate.privacyLevel = .sensitive   // never injected into LLM context

        guard candidate.confidence * candidate.importance >= BrainMemoryStore.autoCommitThreshold else { return }

        Task {
            let committed = await BrainMemoryStore.shared.commit(candidate)
            if committed {
                EpisodeStore.shared.recordApp("Home Assistant")
                log.info("brain.ha-bridge: committed '\(title)'")
            }
        }
    }

    // MARK: - Classification

    /// Returns (title, summary, importance) for events we care about, nil to skip.
    private func classify(_ event: HAEntityChangedEvent) -> (String, String, Double)? {
        switch event.domain {
        case "lock":
            let action = event.newState == "locked" ? "locked" : "unlocked"
            let title   = "Lock \(action): \(friendlyName(event.entityID))"
            let summary = "\(friendlyName(event.entityID)) was \(action)"
            return (title, summary, 0.65)

        case "alarm_control_panel":
            let importance: Double
            let action: String
            switch event.newState {
            case "triggered":
                importance = 0.95
                action     = "TRIGGERED"
            case "armed_away", "armed_home", "armed_night":
                importance = 0.70
                action     = "armed (\(event.newState.replacingOccurrences(of: "armed_", with: "")))"
            case "disarmed":
                importance = 0.70
                action     = "disarmed"
            default:
                return nil
            }
            let title   = "Alarm \(action): \(friendlyName(event.entityID))"
            let summary = "Home alarm \(action)"
            return (title, summary, importance)

        default:
            return nil
        }
    }

    /// Converts "lock.front_door" → "front door".
    private func friendlyName(_ entityID: String) -> String {
        let withoutDomain = entityID.split(separator: ".").dropFirst().joined(separator: " ")
        return withoutDomain.replacingOccurrences(of: "_", with: " ")
    }
}
