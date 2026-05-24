import Foundation

// MARK: - GlobalProactivityCoordinator

/// Routes proactivity signals to the correct device surface.
/// High-urgency signals always fire on Mac. Low-urgency ambient signals
/// may be delegated to Windows when the user is exclusively present there.
@MainActor
final class GlobalProactivityCoordinator {

    static let shared = GlobalProactivityCoordinator()

    // MARK: - Routing rules

    struct RoutingDecision {
        let targetDeviceId: String
        let deliverOnMac: Bool
        let deliverOnWindows: Bool
        let reason: String
    }

    /// Determines which device(s) should deliver the proactive event.
    func route(_ event: ProactiveEvent) -> RoutingDecision {
        let macId = DistributedOrchestrationEngine.macDeviceId
        let windowsSnap = GlobalPresenceAggregator.shared.windowsPresence

        // Critical and high urgency always handled on Mac — it is the authority.
        if event.urgency == .critical || event.urgency == .high {
            return RoutingDecision(
                targetDeviceId: macId,
                deliverOnMac: true,
                deliverOnWindows: false,
                reason: "high urgency → mac authority"
            )
        }

        // User only on Windows, not at Mac → route to Windows.
        let windowsUserPresent = windowsSnap?.isUserPresent == true
        let macIsListening = AttentionContextProvider.shared?.isMacListening ?? false

        if windowsUserPresent && !macIsListening {
            return RoutingDecision(
                targetDeviceId: "windows",
                deliverOnMac: false,
                deliverOnWindows: true,
                reason: "user on windows only"
            )
        }

        // User in coding flow on Windows — show overlay there, speak on Mac briefly.
        if windowsSnap?.attentionLevel == .codingFlow {
            return RoutingDecision(
                targetDeviceId: macId,
                deliverOnMac: true,
                deliverOnWindows: true,
                reason: "coding flow — dual surface"
            )
        }

        // Default: Mac handles.
        return RoutingDecision(
            targetDeviceId: macId,
            deliverOnMac: true,
            deliverOnWindows: false,
            reason: "default mac"
        )
    }

    /// Delivers the event: publishes to Mac orchestrator and optionally queues
    /// an SSE push for Windows via MacBridgeProtocolV2.
    func publish(_ event: ProactiveEvent) {
        let decision = route(event)

        if decision.deliverOnMac {
            ProactivityOrchestrator.shared.publish(event)
        }

        // Daemon routing handles proactive delivery to Windows — MacBridgeProtocolV2 is deprecated.
        // JarvisBrainDaemon routes proactive.notify messages via its own WebSocket sessions.
        _ = decision.deliverOnWindows
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
