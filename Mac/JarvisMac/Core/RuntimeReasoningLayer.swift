import Foundation

// MARK: - RuntimeReasoningLayer

/// Produces human-readable explanations of why Jarvis made specific runtime decisions.
///
/// This is the "meta-awareness" layer — it can answer questions like:
/// - "Why didn't you tell me about that notification?"
/// - "Why did you interrupt yourself?"
/// - "What are you doing right now?"
///
/// Reads from `JarvisRuntimeCoordinator.recentDecisions`, `AttentionPolicy` state,
/// and `ProactivityOrchestrator` to build factual, non-hallucinated explanations.
@MainActor
enum RuntimeReasoningLayer {

    // MARK: - Public API

    /// Explain the most recent coordinator decision.
    static func explainLastDecision() -> String {
        let coordinator = JarvisRuntimeCoordinator.shared
        guard let last = coordinator.recentDecisions.last else {
            return "I haven't made any notable decisions recently."
        }
        return explain(last)
    }

    /// Explain why a specific event was or wasn't delivered.
    static func explainDeliveryDecision(for signal: ProactivitySignal) -> String {
        // Build an attention context snapshot and explain what the policy would decide
        let ctx = AmbientWorldState.shared.attentionContext(
            timingEngine: ConversationalTimingEngine.shared,
            recentInterruptionCount: 0
        )
        let policy = AttentionPolicy()
        let event = ProactiveEvent(
            source: .system,
            urgency: ProactiveUrgency.from(priority: signal.priority),
            title: signal.title,
            body: signal.body
        )
        let decision = policy.decide(event: event, context: ctx)
        return explainPolicyDecision(decision, signal: signal, context: ctx)
    }

    /// Generate a "what am I doing right now" summary.
    static func currentStateSummary() -> String {
        var parts: [String] = []

        let timing = ConversationalTimingEngine.shared
        let world = AmbientWorldState.shared
        let streaming = StreamingConversationEngine.shared

        if timing.isSpeechActive {
            parts.append("I'm listening to you right now")
        } else if timing.isTTSActive {
            if streaming.isStreaming {
                parts.append("I'm in the middle of a streaming response")
            } else {
                parts.append("I'm speaking a response")
            }
        } else {
            parts.append("I'm in standby")
        }

        if let app = world.activeApp {
            parts.append("you're in \(app)")
        }

        if world.hasUpcomingMeeting, let min = world.minutesUntilNextMeeting {
            parts.append("you have a meeting in \(min) minutes")
        }

        if world.isInConversation {
            parts.append("we're in an active conversation")
        }

        let visionSummary = VisionStateSummary.isUserPresent ? "at desk" : "away"
        parts.append("presence: \(visionSummary)")

        let pivotPlanner = ConversationalPivotPlanner.shared
        if pivotPlanner.isActive {
            parts.append("streaming \(pivotPlanner.diagnosticSummary)")
        }

        let coordinator = JarvisRuntimeCoordinator.shared
        parts.append("coordinator: \(coordinator.diagnosticSummary)")

        return parts.joined(separator: "; ")
    }

    /// Explain what Jarvis knows about the user's current work context.
    static func workContextExplanation() -> String {
        let world = AmbientWorldState.shared
        var lines: [String] = []

        if let app = world.activeApp {
            lines.append("You're currently in \(app).")
        }
        if let project = world.activeProject {
            lines.append("The active project appears to be \(project).")
        }

        // Recent episodic memories for current project
        let retriever = EpisodicMemoryRetriever.shared
        let memories = retriever.forCurrentProject(limit: 3)
        if !memories.isEmpty {
            lines.append("Recent context I have:")
            for m in memories {
                lines.append("  - \(m.title): \(m.text.prefix(80))")
            }
        }

        let vision = VisionStateSummary.oneLiner()
        lines.append(vision)

        return lines.isEmpty ? "I don't have enough context about your current work." :
            lines.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func explain(_ decision: CoordinationDecision) -> String {
        let from = decision.demand.submittedBy
        let ago = Int(Date().timeIntervalSince(decision.decidedAt))
        let timeStr = ago < 60 ? "\(ago) seconds ago" : "\(ago / 60) minutes ago"

        switch decision.outcome {
        case .executed(let reason):
            return "I fulfilled a request from \(from) \(timeStr): \(reason)."
        case .deferred(let reason):
            return "I deferred a request from \(from) \(timeStr): \(reason)."
        case .suppressed(let reason):
            return "I suppressed a request from \(from) \(timeStr): \(reason)."
        case .pending:
            return "There's a pending request from \(from) not yet resolved."
        }
    }

    private static func explainPolicyDecision(
        _ decision: ProactiveDeliveryDecision,
        signal: ProactivitySignal,
        context: AttentionContext
    ) -> String {
        var parts = ["The notification '\(signal.title)' "]
        switch decision {
        case .speakNow:
            parts.append("was spoken immediately because conditions were clear.")
        case .defer_:
            if context.isUserSpeaking {
                parts.append("was deferred because you were speaking.")
            } else if context.isJarvisSpeaking {
                parts.append("was deferred because I was speaking.")
            } else {
                parts.append("was deferred to a better moment.")
            }
        case .bundle:
            parts.append("was bundled with other notifications to avoid interrupting you too frequently.")
        case .overlayOnly:
            if context.isInActiveMeeting {
                parts.append("was shown silently because you're in a meeting.")
            } else {
                parts.append("was shown in the overlay without speaking.")
            }
        case .silentMemory:
            parts.append("was stored silently because conditions weren't right to surface it.")
        case .suppress:
            parts.append("was suppressed — priority too low for current context.")
        }
        return parts.joined()
    }
}

private extension ProactiveUrgency {
    static func from(priority: SignalPriority) -> ProactiveUrgency {
        switch priority {
        case .critical, .urgent: return .critical
        case .high:              return .high
        case .normal:            return .normal
        case .low:               return .low
        }
    }
}
