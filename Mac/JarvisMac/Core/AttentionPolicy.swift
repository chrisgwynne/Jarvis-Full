import Foundation

// MARK: - AttentionContext

/// Snapshot of the user's current attentional state.
/// Populated by ProactivityOrchestrator before each delivery decision.
struct AttentionContext {
    var isUserSpeaking: Bool = false
    var isJarvisSpeaking: Bool = false
    var isListening: Bool = false
    var isFocusModeActive: Bool = false
    var isInActiveMeeting: Bool = false
    var currentApp: String? = nil
    var emotionalTone: DialogueTurn.EmotionalTone = .neutral
    var secondsSinceLastInterruption: Double = .infinity
    var secondsSinceLastConversation: Double = .infinity
    var isUserAtHome: Bool = true
    var recentInterruptionCount: Int = 0       // interruptions in last 10 min
    var conversationDepth: Int = 0             // turns in current session
}

// MARK: - AttentionPolicy

/// Gate that checks whether a proactive event should be delivered right now
/// given the user's current attentional state.
///
/// This sits between the ProactivityOrchestrator's delivery queue and the
/// actual speak/overlay call. It never prevents delivery permanently — it
/// defers or bundles instead.
@MainActor
struct AttentionPolicy {

    // MARK: - Thresholds

    var minInterruptionGapSeconds: Double = 15
    var maxInterruptionsPerTenMinutes: Int = 6
    var deepWorkApps: Set<String> = ["Xcode", "cursor", "VSCode", "IntelliJ", "Android Studio"]
    var meetingApps:  Set<String> = ["Zoom", "Teams", "FaceTime", "Google Meet", "Loom"]
    var criticalBypassesAll: Bool = true

    // MARK: - Decision

    /// Returns the delivery decision for an event in the given attention context.
    func decide(event: ProactiveEvent, context: AttentionContext) -> ProactiveDeliveryDecision {

        // Critical events always get through (smoke, security, immediate departure)
        if event.urgency == .critical && criticalBypassesAll {
            return .speakNow
        }

        // Never interrupt while the user or Jarvis is speaking
        if context.isUserSpeaking || context.isJarvisSpeaking {
            return .defer_
        }

        // Defer during confirmed meetings
        if context.isInActiveMeeting {
            return event.urgency >= .high ? .overlayOnly : .suppress
        }

        // Deep work: high urgency → overlay, else suppress/defer
        if let app = context.currentApp, deepWorkApps.contains(where: { app.contains($0) }) {
            if event.urgency >= .high { return .overlayOnly }
            return .defer_
        }

        // Frustration/stress: ease off proactivity
        if context.emotionalTone == .frustrated || context.emotionalTone == .stressed {
            if event.urgency < .high { return .bundle }
        }

        // Tired user: only high/critical
        if context.emotionalTone == .tired {
            if event.urgency < .high { return .silentMemory }
        }

        // Spam guard: too many recent interruptions
        if context.recentInterruptionCount >= maxInterruptionsPerTenMinutes {
            return event.urgency >= .high ? .bundle : .suppress
        }

        // Minimum gap between interruptions
        if context.secondsSinceLastInterruption < minInterruptionGapSeconds {
            return .bundle
        }

        // Deep conversation in progress: low priority can wait
        if context.conversationDepth > 3 && event.urgency == .low {
            return .bundle
        }

        // Check event's own interruptibility score
        if event.interruptibilityScore < 0.40 {
            return .bundle
        }

        return .speakNow
    }

    /// Returns true if it's currently quiet hours (22:00–07:00 local).
    /// Critical events still bypass this.
    func isQuietHours() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 22 || hour < 7
    }
}
