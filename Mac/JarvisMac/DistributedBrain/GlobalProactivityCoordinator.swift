import Foundation

// MARK: - GlobalProactivityCoordinator

/// Routes proactivity signals to the correct device surface.
/// Mac is always the authority for signal delivery.
/// Windows delivery is handled entirely by JarvisBrainDaemon routing —
/// it pushes proactive.notify messages to connected Windows clients via
/// its own authenticated WebSocket sessions.
@MainActor
final class GlobalProactivityCoordinator {

    static let shared = GlobalProactivityCoordinator()

    // MARK: - Routing rules

    struct RoutingDecision {
        let targetDeviceId: String
        let deliverOnMac: Bool
        let reason: String
    }

    /// Determines which device(s) should deliver the proactive event.
    /// Mac always handles delivery; Windows routing is owned by JarvisBrainDaemon.
    func route(_ event: ProactiveEvent) -> RoutingDecision {
        let macId = DistributedOrchestrationEngine.macDeviceId

        // Critical and high urgency always handled on Mac — it is the authority.
        if event.urgency == .critical || event.urgency == .high {
            return RoutingDecision(
                targetDeviceId: macId,
                deliverOnMac: true,
                reason: "high urgency → mac authority"
            )
        }

        // All other cases: Mac handles. JarvisBrainDaemon routes to Windows separately.
        return RoutingDecision(
            targetDeviceId: macId,
            deliverOnMac: true,
            reason: "default mac — daemon routes to windows"
        )
    }

    /// Delivers the event to the Mac orchestrator.
    /// Windows delivery is handled by JarvisBrainDaemon routing.
    func publish(_ event: ProactiveEvent) {
        let decision = route(event)

        if decision.deliverOnMac {
            ProactivityOrchestrator.shared.publish(event)
        }
    }
}

// MARK: - AttentionContextProvider

/// Thin shim so GlobalProactivityCoordinator can check Mac listening state
/// without a direct dependency on JarvisController.
@MainActor
final class AttentionContextProvider {
    static var shared: AttentionContextProvider?
    var isMacListening: Bool = false
    var isMacSpeaking: Bool = false
}
