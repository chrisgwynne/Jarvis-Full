import Foundation

/// Registers RuntimeSubsystem shells and marks RuntimeCoordinator ready or degraded.
///
/// Extracted from JarvisController.bootstrap() — Sprint N decomposition.
/// Preserves the exact startup order required by RuntimeDependencyGraph.
@MainActor
enum RuntimeBootstrapper {

    /// Registers the 9 subsystem shells with RuntimeCoordinator.shared and marks
    /// the coordinator ready (or degraded-ready if audio/conversation are impaired).
    ///
    /// - Parameters:
    ///   - appState: Shared UI state — passed to subsystems that health-check it.
    ///   - conversation: The live ConversationRuntime instance (registered directly,
    ///     not as a shell, so its real start/stop/healthCheck methods are used).
    ///   - systemsDegraded: Pass true when microphone or speech auth was denied.
    static func registerAndMarkReady(
        appState: AppState,
        conversation: ConversationRuntime,
        systemsDegraded: Bool
    ) {
        let coord = RuntimeCoordinator.shared
        coord.register(SystemRuntime(appState: appState))
        coord.register(MemoryRuntime())
        coord.register(BrainRuntime())
        coord.register(AudioRuntime(appState: appState))
        coord.register(conversation)           // real ConversationRuntime, not a shell
        coord.register(OverlayRuntime())
        coord.register(AmbientRuntime())
        coord.register(LLMRuntime(appState: appState))
        coord.register(ProactivityRuntime())
        coord.register(AndroidRuntime(appState: appState))
        let degradedIDs = systemsDegraded ? Set(["audio", "conversation"]) : Set<String>()
        if degradedIDs.isEmpty {
            coord.markReady()
        } else {
            coord.markDegradedReady(degradedIDs)
        }
    }
}
