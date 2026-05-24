import Foundation

// MARK: - ProactivityOrchestrator

/// Persistent attention-aware orchestrator that sits above the existing
/// `ProactivityEngine`.
///
/// All integrations can publish `ProactiveEvent` values here. The orchestrator
/// runs a 30-second delivery cycle, applies `AttentionPolicy`, and routes events
/// through to ProactivityEngine for actual speak/overlay delivery.
///
/// Distinct from ProactivityEngine:
/// - ProactivityEngine handles per-signal cooldowns, quiet hours, and tray management.
/// - ProactivityOrchestrator handles bundling, deferral, escalation, and attention-gating
///   at a higher level before signals ever reach the engine.
@MainActor
final class ProactivityOrchestrator {
    static let shared = ProactivityOrchestrator()

    // MARK: - Wired callbacks (set by JarvisController)

    var onSpeak:   ((String) -> Void)?
    var onSignal:  ((ProactivitySignal) -> Void)?
    var getAttentionContext: (() -> AttentionContext)?

    // MARK: - Configuration

    var attentionPolicy = AttentionPolicy()
    var deliveryCycleSeconds: Double = 30
    var bundleWindow: Int = 3              // max events to merge into one summary
    var escalationThresholdSeconds: Double = 300   // defer→deliver after 5 min

    // MARK: - Internal state

    private var pendingEvents: [ProactiveEvent] = []
    private var deliveredEventIDs: Set<UUID> = []
    private var deferredEvents: [(event: ProactiveEvent, deferredAt: Date)] = []
    private var lastDeliveryTime: [ProactiveEventSource: Date] = [:]
    private var recentDeliveryTimes: [Date] = []
    private var deliveryCycleTask: Task<Void, Never>? = nil
    /// Original signals stored by event ID so delivery can use spokenText/overlayKind.
    private var pendingSignals: [UUID: ProactivitySignal] = [:]

    // MARK: - Lifecycle

    func start() {
        deliveryCycleTask?.cancel()
        deliveryCycleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(deliveryCycleSeconds))
                if !Task.isCancelled {
                    await runDeliveryCycle()
                }
            }
        }
    }

    func stop() {
        deliveryCycleTask?.cancel()
        deliveryCycleTask = nil
    }

    // MARK: - Publish

    /// All integrations call this to publish a proactive event.
    func publish(_ event: ProactiveEvent) {
        guard !deliveredEventIDs.contains(event.id) else { return }
        guard !event.isExpired else { return }
        pendingEvents.append(event)
        // For critical events, attempt immediate delivery without waiting for cycle
        if event.urgency == .critical {
            Task { await runDeliveryCycle() }
        }
    }

    /// Provider-facing publish — converts a ProactivitySignal into a ProactiveEvent,
    /// stores the original signal for delivery, and triggers immediate delivery for
    /// high-urgency events without waiting for the next 30-second cycle.
    func providerPublish(signal: ProactivitySignal) {
        let urgency = signalPriorityToUrgency(signal.priority)
        let source  = signalSourceToEventSource(signal.source)
        let event   = ProactiveEvent(source: source, urgency: urgency,
                                     title: signal.title, body: signal.body)
        pendingSignals[event.id] = signal
        publish(event)
        if urgency >= .high {
            Task { await runDeliveryCycle() }
        }
    }

    // MARK: - Priority / source mapping

    private func signalPriorityToUrgency(_ p: SignalPriority) -> ProactiveUrgency {
        switch p {
        case .critical, .urgent: return .critical
        case .high:              return .high
        case .normal:            return .normal
        case .low:               return .low
        }
    }

    private func signalSourceToEventSource(_ s: SignalSource) -> ProactiveEventSource {
        switch s {
        case .calendar:      return .calendar
        case .todoist:       return .todoist
        case .github:        return .github
        case .homeAssistant: return .homeAssistant
        case .shopify:       return .shopify
        case .email:         return .email
        case .news:          return .news
        case .system, .memory, .obsidian, .android: return .system
        }
    }

    // MARK: - Delivery cycle

    private func runDeliveryCycle() async {
        escalateDeferredEvents()
        pruneExpired()

        let context = getAttentionContext?() ?? AttentionContext()

        // Sort: critical first, then by urgency, then by timestamp
        let sorted = pendingEvents.sorted { a, b in
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            return a.timestamp < b.timestamp
        }

        var toBundle: [ProactiveEvent] = []

        for event in sorted {
            guard !deliveredEventIDs.contains(event.id) else { continue }
            guard !event.isExpired else { markDelivered(event.id); continue }
            guard !isOnCooldown(event) else { continue }

            let decision = attentionPolicy.decide(event: event, context: context)

            switch decision {
            case .speakNow:
                if toBundle.count < bundleWindow {
                    toBundle.append(event)
                }
            case .overlayOnly:
                deliverOverlay(event)
                markDelivered(event.id)
            case .silentMemory:
                deliverSilent(event)
                markDelivered(event.id)
            case .bundle:
                toBundle.append(event)
            case .defer_:
                deferEvent(event)
            case .suppress:
                markDelivered(event.id)
            }
        }

        if !toBundle.isEmpty {
            deliverBundle(toBundle, context: context)
            for e in toBundle { markDelivered(e.id) }
        }

        pendingEvents.removeAll { deliveredEventIDs.contains($0.id) || $0.isExpired }
    }

    // MARK: - Delivery methods

    private func deliverBundle(_ events: [ProactiveEvent], context: AttentionContext) {
        if events.count == 1 {
            deliverSingleEvent(events[0])
            return
        }
        let sorted = events.sorted { $0.urgency > $1.urgency }
        // Collect signals for the events so NoiseController can build natural bundle text
        let signals = sorted.compactMap { pendingSignals[$0.id] }
        let text: String
        if signals.count >= 2, let bundle = ProactivityNoiseController.shared.tryBundle(signals) {
            text = bundle.spokenText
            for s in bundle.signals { ProactivityNoiseController.shared.markDelivered(s) }
        } else {
            // Fallback: use primary spoken text with natural "also" phrasing
            let primary = sorted[0]
            let primaryText = pendingSignals[primary.id]?.spokenText ?? primary.body
            let otherTitles = sorted.dropFirst().compactMap { pendingSignals[$0.id]?.title ?? $0.title }.filter { !$0.isEmpty }
            text = otherTitles.isEmpty
                ? primaryText
                : "\(primaryText) Also — \(otherTitles.joined(separator: " and "))."
        }
        onSpeak?(text)
        recordDelivery(sources: events.map { $0.source })
    }

    private func deliverSingleEvent(_ event: ProactiveEvent) {
        if let signal = pendingSignals[event.id] {
            let text = signal.spokenText ?? signal.body
            onSpeak?(text)
            if signal.overlayKind != nil { onSignal?(signal) }
        } else {
            onSpeak?(event.body)
        }
        recordDelivery(sources: [event.source])
    }

    private func deliverOverlay(_ event: ProactiveEvent) {
        if let signal = pendingSignals[event.id] {
            onSignal?(signal)
        } else {
            let signal = ProactivitySignal(
                id: event.id.uuidString,
                source: mapSource(event.source),
                title: event.title,
                body: event.body,
                priority: mapUrgency(event.urgency),
                dedupeKey: event.id.uuidString
            )
            onSignal?(signal)
        }
    }

    private func deliverSilent(_ event: ProactiveEvent) {
        // Stored silently — no TTS, no overlay
    }

    // MARK: - Escalation

    private func escalateDeferredEvents() {
        let now = Date()
        var toEscalate: [ProactiveEvent] = []
        deferredEvents.removeAll { item in
            let age = now.timeIntervalSince(item.deferredAt)
            if age >= escalationThresholdSeconds {
                toEscalate.append(item.event)
                return true
            }
            return item.event.isExpired
        }
        for event in toEscalate {
            pendingEvents.append(event)
        }
    }

    // MARK: - Helpers

    private func deferEvent(_ event: ProactiveEvent) {
        guard !deferredEvents.contains(where: { $0.event.id == event.id }) else { return }
        deferredEvents.append((event: event, deferredAt: Date()))
        pendingEvents.removeAll { $0.id == event.id }
    }

    private func markDelivered(_ id: UUID) {
        deliveredEventIDs.insert(id)
        pendingSignals.removeValue(forKey: id)
        if deliveredEventIDs.count > 500 { deliveredEventIDs.removeFirst() }
    }

    private func recordDelivery(sources: [ProactiveEventSource]) {
        let now = Date()
        for source in sources { lastDeliveryTime[source] = now }
        recentDeliveryTimes.append(now)
        recentDeliveryTimes.removeAll { now.timeIntervalSince($0) > 600 } // 10-min window
    }

    private func isOnCooldown(_ event: ProactiveEvent) -> Bool {
        guard let last = lastDeliveryTime[event.source] else { return false }
        return Date().timeIntervalSince(last) < event.urgency.defaultCooldownSeconds
    }

    private func pruneExpired() {
        pendingEvents.removeAll { $0.isExpired }
        deferredEvents.removeAll { $0.event.isExpired }
    }

    /// Build AttentionContext from live state — used when no callback is wired.
    func buildDefaultContext(
        isSpeaking: Bool = false,
        isListening: Bool = false,
        currentApp: String? = nil
    ) -> AttentionContext {
        var ctx = AttentionContext()
        ctx.isJarvisSpeaking = isSpeaking
        ctx.isListening = isListening
        ctx.currentApp = currentApp
        ctx.emotionalTone = RollingDialogueMemory.shared.emotionalTone
        ctx.conversationDepth = RollingDialogueMemory.shared.recentTurns.count
        ctx.secondsSinceLastConversation = {
            guard let last = RollingDialogueMemory.shared.turns.last else { return .infinity }
            return Date().timeIntervalSince(last.timestamp)
        }()
        ctx.recentInterruptionCount = recentDeliveryTimes.count
        return ctx
    }

    // MARK: - Source mapping

    private func mapSource(_ s: ProactiveEventSource) -> SignalSource {
        switch s {
        case .calendar:      return .calendar
        case .todoist:       return .todoist
        case .github:        return .github
        case .homeAssistant: return .homeAssistant
        case .shopify:       return .shopify
        case .email:         return .email
        case .news:          return .news
        case .wifi:          return .system
        case .location:      return .system
        case .camera:        return .system
        case .projectState:  return .system
        case .diagnostics:   return .system
        case .system:        return .system
        case .voice:         return .system
        case .brain:         return .system
        }
    }

    private func mapUrgency(_ u: ProactiveUrgency) -> SignalPriority {
        switch u {
        case .critical: return .urgent
        case .high:     return .high
        case .normal:   return .normal
        case .low:      return .low
        }
    }
}
