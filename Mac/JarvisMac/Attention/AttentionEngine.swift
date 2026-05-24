import Foundation
import AppKit

/// Lightweight heuristic engine that derives user attention state from
/// observable signals. No ML — pure rule-based evaluation called
/// whenever key state changes (phase, presence, idle tick).
@Observable
@MainActor
final class AttentionEngine {

    private(set) var state: AttentionState = .unknown
    private(set) var lastTransition: Date = Date()
    private(set) var confidence: Double = 0.5

    // Idle tracking
    private(set) var idleSeconds: Double = 0
    private var lastActivity: Date = Date()
    private var idleTask: Task<Void, Never>?
    private var eventMonitor: Any?

    // Apps that indicate media consumption when fullscreen
    private static let mediaApps: Set<String> = [
        "QuickTime Player", "VLC", "IINA", "Infuse", "Netflix", "Prime Video",
        "Disney+", "Spotify", "Apple Music", "TV", "Plex", "Vimeo"
    ]

    // MARK: - Lifecycle

    func start() {
        startIdleMonitor()
        startEventMonitor()
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    // MARK: - Evaluation

    /// Evaluate signals and update state. Call whenever inputs change.
    @discardableResult
    func evaluate(_ signals: AttentionSignals) -> AttentionState {
        let new = compute(signals)
        if new != state {
            let old = state
            state = new
            lastTransition = Date()
            confidence = confidenceFor(new, signals: signals)
            let conf = self.confidence
            Log.app.info("attention: \(old.rawValue) → \(new.rawValue) (idle \(Int(signals.idleSeconds))s, confidence \(String(format: "%.2f", conf)))")
        }
        return state
    }

    /// Build signals from AppState and evaluate. Convenience for JarvisController.
    @discardableResult
    func evaluateFromState(
        presenceDetected: Bool,
        isConversational: Bool,
        isSpeaking: Bool,
        isListening: Bool,
        activeAppName: String,
        overlayOpen: Bool,
        screenWatching: Bool,
        cameraWatching: Bool
    ) -> AttentionState {
        let signals = AttentionSignals(
            presenceDetected: presenceDetected,
            isConversational: isConversational,
            isSpeaking: isSpeaking,
            isListening: isListening,
            isFullscreen: isAppFullscreen(),
            activeAppName: activeAppName,
            idleSeconds: idleSeconds,
            overlayOpen: overlayOpen,
            screenWatching: screenWatching,
            cameraWatching: cameraWatching
        )
        return evaluate(signals)
    }

    // MARK: - Private computation

    private func compute(_ s: AttentionSignals) -> AttentionState {
        // Conversational: Jarvis is actively talking or listening
        if s.isConversational || s.isListening || s.isSpeaking {
            return .conversational
        }
        // Away: no camera presence AND idle > 5 min
        if !s.presenceDetected && s.idleSeconds > 300 {
            return .away
        }
        // Idle: no activity for 2 min
        if s.idleSeconds > 120 {
            return .idle
        }
        // Fullscreen classification
        if s.isFullscreen {
            return Self.mediaApps.contains(s.activeAppName) ? .mediaConsumption : .fullscreenFocus
        }
        // Overlay open = user focused on Jarvis output
        if s.overlayOpen {
            return .focused
        }
        // Default
        return s.presenceDetected ? .passive : .unknown
    }

    private func confidenceFor(_ state: AttentionState, signals: AttentionSignals) -> Double {
        switch state {
        case .conversational:   return 0.95
        case .away:             return signals.presenceDetected ? 0.40 : 0.88
        case .idle:             return min(1.0, signals.idleSeconds / 300.0)
        case .mediaConsumption: return 0.80
        case .fullscreenFocus:  return 0.75
        case .focused:          return 0.70
        case .passive:          return signals.presenceDetected ? 0.65 : 0.40
        case .unknown:          return 0.25
        }
    }

    // MARK: - Fullscreen detection

    private func isAppFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let pid = app.processIdentifier
        for info in list {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? Int32,
                  windowPID == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
            if w >= screen.width - 4 && h >= screen.height - 4 { return true }
        }
        return false
    }

    // MARK: - Idle monitor

    private func startIdleMonitor() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.idleSeconds = max(0, -self.lastActivity.timeIntervalSinceNow)
            }
        }
    }

    private func startEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastActivity = Date()
                self?.idleSeconds = 0
            }
        }
    }
}
