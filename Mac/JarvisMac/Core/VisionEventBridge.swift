import Foundation

/// Routes VisionModule motion and threat callbacks into ProactivityEngine.
///
/// Extracted from JarvisController.bootstrap() — Sprint N decomposition.
/// Held strongly by JarvisController so the weak-self closure captures remain live.
@MainActor
final class VisionEventBridge {

    private let proactivity: ProactivityEngine
    private let appState: AppState

    init(proactivity: ProactivityEngine, appState: AppState) {
        self.proactivity = proactivity
        self.appState = appState
    }

    /// Assigns VisionModule callbacks. Safe to call once during bootstrap.
    func wire(to visionModule: VisionModule) {
        visionModule.onMotionZoneTriggered = { [weak self] zone, intensity in
            guard let self else { return }
            Task { @MainActor in self.handleMotion(zone: zone, intensity: intensity) }
        }
        visionModule.onThreatEscalated = { [weak self] level, reason in
            guard let self, level >= .suspicious else { return }
            Task { @MainActor in self.handleThreat(level: level, reason: reason) }
        }
    }

    // MARK: - Private handlers

    private func handleMotion(zone: MotionZoneDescriptor, intensity: Float) {
        let signal = ProactivitySignal(
            source: .homeAssistant,
            title: "Motion Detected",
            body: "Motion in \(zone.name)",
            priority: intensity > 0.5 ? .urgent : .normal,
            dedupeKey: "vision.motion.\(zone.id.uuidString)",
            overlayKind: .surveillance
        )
        proactivity.ingest(signal, appState: appState)
    }

    private func handleThreat(level: ThreatLevel, reason: String) {
        let signal = ProactivitySignal(
            source: .homeAssistant,
            title: level.systemLabel,
            body: reason,
            priority: level == .alert ? .urgent : .normal,
            dedupeKey: "vision.threat.\(level.rawValue)",
            overlayKind: .surveillance
        )
        proactivity.ingest(signal, appState: appState)
    }
}
