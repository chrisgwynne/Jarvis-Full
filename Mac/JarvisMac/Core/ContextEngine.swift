import Foundation
import AppKit

/// In-memory rollup of everything Jarvis currently knows about the
/// world, fed by the controller after every event and queryable by the
/// intent router before it falls through to `.unknown`. Persisted history
/// lives in `ContextStore`.
@MainActor
final class ContextEngine {

    struct Snapshot: Equatable {
        var phase: AssistantPhase = .idle
        var currentTranscript: String = ""
        var lastCommand: String = ""
        var lastAndroidContext: String = ""
        var lastCameraSummary: String = ""
        var lastPresenceSummary: String = ""
        var lastScreenSummary: String = ""
        var lastHomeSummary: String = ""
        var activeAppName: String = ""
        var recentActions: [String] = []
        var updatedAt: Date = Date()

        // Sprint 8.5 additions
        var attentionState: AttentionState = .unknown
        var operatingMode: OperatingMode = .normal
        var openOverlays: [String] = []           // overlay kind raw values
        var recentActivityTitles: [String] = []   // last 5 timeline events
        var topEntityLabels: [String] = []        // top 5 entity labels
        var pendingNotificationCount: Int = 0
        var newsHeadlines: [String] = []          // up to 3 recent article titles

        // Android phone context — for follow-up intents
        var lastCallerName: String = ""           // most recent incoming/missed caller
        var lastMissedCallerName: String = ""     // specifically missed (for "call back")
        var lastSMSSender: String = ""            // for "reply saying"
        var lastWhatsAppSender: String = ""       // for "reply saying" (WhatsApp path)
        var lastPhoneEventType: String = ""       // raw event type string

        // Identity — populated from PreferencesStore on bootstrap and pref changes.
        // Included in summaryString() so LLM fallback always knows who it's talking to.
        var userName: String = ""
        var assistantName: String = "Jarvis"

        func summaryString() -> String {
            var lines: [String] = []
            // Identity lines come first so they're near the token budget start.
            if !userName.isEmpty      { lines.append("userName: \(userName)") }
            lines.append("assistantName: \(assistantName)")
            lines.append("phase: \(phase.rawValue)")
            if !currentTranscript.isEmpty { lines.append("transcript: \(currentTranscript)") }
            if !lastCommand.isEmpty       { lines.append("last command: \(lastCommand)") }
            if !activeAppName.isEmpty     { lines.append("active app: \(activeAppName)") }
            if attentionState != .unknown { lines.append("attention: \(attentionState.rawValue)") }
            if operatingMode != .normal   { lines.append("mode: \(operatingMode.rawValue)") }
            if !openOverlays.isEmpty      { lines.append("overlays: \(openOverlays.joined(separator: ","))") }
            if !lastCameraSummary.isEmpty  { lines.append("camera: \(lastCameraSummary)") }
            if !lastPresenceSummary.isEmpty { lines.append("presence: \(lastPresenceSummary)") }
            if !lastScreenSummary.isEmpty  { lines.append("screen: \(lastScreenSummary)") }
            if !lastHomeSummary.isEmpty    { lines.append("home: \(lastHomeSummary)") }
            if !lastAndroidContext.isEmpty { lines.append("android: \(lastAndroidContext)") }
            if !recentActivityTitles.isEmpty {
                lines.append("activity: " + recentActivityTitles.joined(separator: " | "))
            }
            if !topEntityLabels.isEmpty {
                lines.append("entities: " + topEntityLabels.joined(separator: ", "))
            }
            if !newsHeadlines.isEmpty {
                lines.append("news: " + newsHeadlines.joined(separator: " | "))
            }
            if !lastCallerName.isEmpty {
                lines.append("lastCaller: \(lastCallerName)")
            }
            if !lastMissedCallerName.isEmpty {
                lines.append("missedCaller: \(lastMissedCallerName)")
            }
            if !lastSMSSender.isEmpty {
                lines.append("lastSMSFrom: \(lastSMSSender)")
            }
            if !lastWhatsAppSender.isEmpty {
                lines.append("lastWhatsAppFrom: \(lastWhatsAppSender)")
            }
            if !recentActions.isEmpty {
                lines.append("recent: " + recentActions.suffix(5).joined(separator: " | "))
            }
            return lines.joined(separator: "\n")
        }
    }

    private(set) var snapshot = Snapshot()
    private let store: ContextStore

    init(store: ContextStore) {
        self.store = store
        observeActiveApp()
    }

    func recordTranscript(_ text: String, final: Bool) {
        snapshot.currentTranscript = text
        snapshot.updatedAt = Date()
        if final {
            store.append(ContextEntry(kind: .transcript, summary: text))
        }
    }

    func recordIntent(_ intent: Intent, raw: String) {
        snapshot.lastCommand = raw
        snapshot.recentActions.append("intent:\(shortDescription(of: intent))")
        trimRecent()
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .intent, summary: "\(raw) → \(shortDescription(of: intent))"))
    }

    func recordAction(_ summary: String) {
        snapshot.recentActions.append("action:\(summary)")
        trimRecent()
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .action, summary: summary))
    }

    func recordCamera(_ summary: String) {
        snapshot.lastCameraSummary = summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .camera, summary: summary))
    }

    func recordCameraScene(_ scene: CameraScene) {
        snapshot.lastCameraSummary = scene.summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .cameraScene, summary: scene.summary))
    }

    func recordPresence(_ state: PresenceState) {
        snapshot.lastPresenceSummary = state.summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .cameraPresence, summary: state.summary))
    }

    func recordCameraWatch(_ summary: String) {
        snapshot.recentActions.append("camera-watch:\(summary.prefix(40))")
        trimRecent()
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .cameraWatch, summary: summary))
    }

    func recordCameraMotion(_ event: CameraMotionEvent) {
        snapshot.recentActions.append("camera-motion:\(String(format: "%.2f", event.delta))")
        trimRecent()
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .cameraMotion, summary: event.summary))
    }

    func setActiveApp(_ name: String) {
        snapshot.activeAppName = name
        snapshot.updatedAt = Date()
    }

    func recordScreen(_ summary: String) {
        snapshot.lastScreenSummary = summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .screen, summary: summary))
    }

    func recordHome(_ summary: String) {
        snapshot.lastHomeSummary = summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .home, summary: summary))
    }

    func recordAndroid(_ summary: String) {
        snapshot.lastAndroidContext = summary
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .android, summary: summary))
    }

    /// Record an Android phone event — updates conversation context so follow-up
    /// intents like "call him back" and "reply saying" can resolve without prompting.
    func recordAndroidEvent(_ event: AndroidPhoneEvent) {
        snapshot.lastPhoneEventType = event.type.rawValue
        snapshot.lastAndroidContext = "\(event.type.displayName)\(event.senderName.map { " from \($0)" } ?? "")"
        snapshot.updatedAt = Date()

        switch event.type {
        case .incomingCall, .callAnswered:
            if let name = event.senderName {
                snapshot.lastCallerName = name
            }
        case .missedCall:
            if let name = event.senderName {
                snapshot.lastCallerName = name
                snapshot.lastMissedCallerName = name
            }
        case .smsReceived:
            if let name = event.senderName {
                snapshot.lastSMSSender = name
            }
        case .whatsAppReceived:
            if let name = event.senderName {
                snapshot.lastWhatsAppSender = name
            }
        default:
            break
        }

        store.append(ContextEntry(
            kind: .android,
            summary: snapshot.lastAndroidContext
        ))
    }

    func recordBargeIn(reason: String) {
        snapshot.recentActions.append("barge-in:\(reason)")
        trimRecent()
        snapshot.updatedAt = Date()
        store.append(ContextEntry(kind: .bargeIn, summary: reason))
    }

    func recordWake(_ event: WakeWordEvent) {
        snapshot.recentActions.append("wake:\(event.keyword) \(String(format: "%.2f", event.confidence))")
        trimRecent()
        store.append(ContextEntry(kind: .wake, summary: "\(event.keyword) @ \(event.confidence)"))
    }

    func setPhase(_ phase: AssistantPhase) {
        snapshot.phase = phase
        snapshot.updatedAt = Date()
    }

    func setAttention(_ state: AttentionState) {
        snapshot.attentionState = state
        snapshot.updatedAt = Date()
    }

    func setOperatingMode(_ mode: OperatingMode) {
        snapshot.operatingMode = mode
        snapshot.updatedAt = Date()
    }

    func setOpenOverlays(_ kinds: [String]) {
        snapshot.openOverlays = kinds
        snapshot.updatedAt = Date()
    }

    func setRecentActivity(_ titles: [String]) {
        snapshot.recentActivityTitles = Array(titles.suffix(5))
        snapshot.updatedAt = Date()
    }

    func setTopEntities(_ labels: [String]) {
        snapshot.topEntityLabels = Array(labels.prefix(5))
        snapshot.updatedAt = Date()
    }

    func setPendingNotifications(_ count: Int) {
        snapshot.pendingNotificationCount = count
        snapshot.updatedAt = Date()
    }

    func setNewsHeadlines(_ headlines: [String]) {
        snapshot.newsHeadlines = Array(headlines.prefix(3))
        snapshot.updatedAt = Date()
    }

    /// Sync identity fields from PreferencesStore into the snapshot so the
    /// LLM fallback always knows who it's talking to without a separate lookup.
    func setIdentity(userName: String, assistantName: String) {
        snapshot.userName = userName
        snapshot.assistantName = assistantName.isEmpty ? "Jarvis" : assistantName
        snapshot.updatedAt = Date()
    }

    private func trimRecent() {
        if snapshot.recentActions.count > 20 {
            snapshot.recentActions.removeFirst(snapshot.recentActions.count - 20)
        }
    }

    // MARK: - Active app

    private func observeActiveApp() {
        snapshot.activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // NSWorkspace posts didActivateApplicationNotification on its own
        // notification center, not the default one. Subscribing to
        // NotificationCenter.default here would silently never fire.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.snapshot.activeAppName = app?.localizedName ?? ""
                if let name = app?.localizedName {
                    self?.store.append(ContextEntry(kind: .activeApp, summary: name))
                }
            }
        }
    }

    private func shortDescription(of intent: Intent) -> String {
        switch intent {
        case .openApp(let n):          return "openApp(\(n))"
        case .openURL(let u):          return "openURL(\(u.host ?? u.absoluteString))"
        case .homeTurnOn(let e):       return "homeOn(\(e))"
        case .homeTurnOff(let e):      return "homeOff(\(e))"
        case .homeQueryEntity(let e):  return "homeQ(\(e))"
        case .unknown(let t):          return "unknown(\(t.prefix(24)))"
        default: return "\(intent)"
        }
    }
}
