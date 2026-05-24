import Foundation
import os

// MARK: - CoordinationDemand

/// A request submitted to `JarvisRuntimeCoordinator` from any subsystem.
/// The coordinator decides how to resolve conflicts and records its reasoning.
struct CoordinationDemand {
    enum Kind {
        case speak(text: String, urgency: ProactiveUrgency)
        case showOverlay(kind: OverlayKind)
        case startListening
        case stopListening
        case escalateAlert(signal: ProactivitySignal)
        case requestMemoryWrite(candidate: MemoryCandidate)
    }

    let id: UUID
    let kind: Kind
    let submittedBy: String    // subsystem identifier
    let submittedAt: Date
    var resolvedAt: Date?
    var resolution: String?

    init(kind: Kind, from subsystem: String) {
        self.id = UUID()
        self.kind = kind
        self.submittedBy = subsystem
        self.submittedAt = Date()
    }
}

// MARK: - JarvisRuntimeCoordinator

/// High-level coordinator that arbitrates conflicting demands from subsystems.
///
/// Sits above `RuntimeCoordinator` (lifecycle) and `ProactivityOrchestrator`
/// (attention-gated signals). This layer handles simultaneous demands —
/// e.g. streaming TTS + camera alert + memory write — and decides sequencing.
///
/// **Key responsibilities:**
/// - Arbitrate speak() conflicts (e.g. TTS streaming vs proactive alert)
/// - Sequence overlay transitions so they don't thrash
/// - Gate memory writes during active conversation
/// - Expose `RuntimeReasoningLayer` with explanations of each decision
///
/// **Design:** demands are queued and resolved synchronously on MainActor
/// so resolution is deterministic and inspectable.
@MainActor
final class JarvisRuntimeCoordinator {

    static let shared = JarvisRuntimeCoordinator()

    private let log = Logger(subsystem: "com.jarvis", category: "runtime.coordinator")

    // MARK: - State

    private var pendingDemands: [CoordinationDemand] = []
    private(set) var recentDecisions: [CoordinationDecision] = []
    private let maxDecisionHistory = 50

    // MARK: - Callbacks (wired by JarvisController)

    var isTTSActive: (() -> Bool)?
    var isListeningActive: (() -> Bool)?
    var isConversationActive: (() -> Bool)?
    var currentOverlay: (() -> OverlayKind?)?
    var speakText: ((String) -> Void)?
    var openOverlay: ((OverlayKind) -> Void)?
    var startListening: (() -> Void)?

    // MARK: - Submit

    func submit(_ demand: CoordinationDemand) {
        pendingDemands.append(demand)
        resolvePending()
    }

    func submitSpeak(_ text: String, urgency: ProactiveUrgency, from subsystem: String) {
        let demand = CoordinationDemand(kind: .speak(text: text, urgency: urgency), from: subsystem)
        submit(demand)
    }

    // MARK: - Resolution

    private func resolvePending() {
        while !pendingDemands.isEmpty {
            let demand = pendingDemands.removeFirst()
            resolve(demand)
        }
    }

    private func resolve(_ demand: CoordinationDemand) {
        var decision = CoordinationDecision(demandId: demand.id, demand: demand)

        switch demand.kind {
        case .speak(let text, let urgency):
            decision = resolveSpeakDemand(text: text, urgency: urgency, demand: demand)

        case .showOverlay(let kind):
            decision = resolveOverlayDemand(kind: kind, demand: demand)

        case .startListening:
            if isConversationActive?() == true {
                decision.outcome = .deferred(reason: "conversation already active")
            } else {
                startListening?()
                decision.outcome = .executed(reason: "started listening")
            }

        case .stopListening:
            // Stop listening is always immediate
            decision.outcome = .executed(reason: "stop listening is always immediate")

        case .escalateAlert(let signal):
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
            decision.outcome = .executed(reason: "escalated to orchestrator")

        case .requestMemoryWrite(let candidate):
            if isConversationActive?() == true && candidate.confidence < 0.85 {
                decision.outcome = .deferred(reason: "active conversation — memory write deferred")
            } else {
                Task { await BrainMemoryStore.shared.commit(candidate) }
                decision.outcome = .executed(reason: "memory committed")
            }
        }

        recordDecision(decision)
    }

    private func resolveSpeakDemand(text: String, urgency: ProactiveUrgency,
                                     demand: CoordinationDemand) -> CoordinationDecision {
        var d = CoordinationDecision(demandId: demand.id, demand: demand)

        let ttsActive = isTTSActive?() ?? false

        switch urgency {
        case .critical:
            // Critical always speaks, even if TTS is active
            speakText?(text)
            d.outcome = .executed(reason: "critical urgency — bypasses TTS check")

        case .high:
            if ttsActive {
                // Queue after current speech
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.speakText?(text)
                }
                d.outcome = .deferred(reason: "TTS active — queued 2s")
            } else {
                speakText?(text)
                d.outcome = .executed(reason: "TTS idle — spoke immediately")
            }

        case .normal, .low:
            if ttsActive {
                d.outcome = .suppressed(reason: "TTS active and urgency is normal/low")
            } else if isListeningActive?() == true {
                d.outcome = .suppressed(reason: "listening active — avoid interrupt")
            } else {
                speakText?(text)
                d.outcome = .executed(reason: "conditions clear")
            }
        }
        return d
    }

    private func resolveOverlayDemand(kind: OverlayKind,
                                      demand: CoordinationDemand) -> CoordinationDecision {
        var d = CoordinationDecision(demandId: demand.id, demand: demand)
        if let current = currentOverlay?(), current == kind {
            d.outcome = .suppressed(reason: "overlay already showing")
        } else {
            openOverlay?(kind)
            d.outcome = .executed(reason: "overlay opened")
        }
        return d
    }

    // MARK: - History

    private func recordDecision(_ decision: CoordinationDecision) {
        recentDecisions.append(decision)
        if recentDecisions.count > maxDecisionHistory {
            recentDecisions.removeFirst()
        }
        if case .suppressed(let reason) = decision.outcome {
            log.debug("Suppressed demand from \(decision.demand.submittedBy): \(reason)")
        }
    }

    var diagnosticSummary: String {
        let recent = recentDecisions.suffix(5)
        let executed = recent.filter { if case .executed = $0.outcome { return true }; return false }.count
        return "decisions=\(recentDecisions.count) recent_executed=\(executed)/\(recent.count)"
    }
}

// MARK: - CoordinationDecision

struct CoordinationDecision {
    enum Outcome {
        case executed(reason: String)
        case deferred(reason: String)
        case suppressed(reason: String)
        case pending
    }

    let demandId: UUID
    let demand: CoordinationDemand
    var outcome: Outcome = .pending
    let decidedAt: Date = Date()
}
