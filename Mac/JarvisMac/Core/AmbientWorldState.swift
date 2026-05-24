import Foundation

// MARK: - AmbientWorldState

/// Central snapshot of everything Jarvis currently knows about the user's world.
/// Aggregated lazily from existing services; subsystems read it when making
/// attention, delivery, or context decisions.
///
/// Updated by JarvisController and individual services. All access is @MainActor.
@MainActor
final class AmbientWorldState {
    static let shared = AmbientWorldState()

    // MARK: - App / focus context

    var activeApp: String?
    var activeWindowTitle: String?
    var activeProject: String?
    var focusConfidence: Double = 0

    // MARK: - Media

    var isMediaPlaying: Bool = false
    var mediaTitle: String?
    var mediaArtist: String?

    // MARK: - Home

    var haConnected: Bool = false
    var lastHAEvent: String?

    // MARK: - Calendar

    var hasUpcomingMeeting: Bool = false
    var nextMeetingTitle: String?
    var minutesUntilNextMeeting: Int?

    // MARK: - Conversation

    var isInConversation: Bool = false
    var conversationDepth: Int = 0
    var lastTranscript: String?

    // MARK: - User state

    var emotionalTone: DialogueTurn.EmotionalTone = .neutral
    var isUserIdle: Bool = false
    var secondsSinceLastInteraction: Double = .infinity

    // MARK: - Network / services

    var isOnline: Bool = true

    // MARK: - Derived queries

    /// True when the user is in a deep-work app (Xcode, Cursor, VSCode, etc.)
    var isInDeepWorkApp: Bool {
        guard let app = activeApp else { return false }
        let deepWorkApps = ["Xcode", "cursor", "VSCode", "IntelliJ", "Android Studio"]
        return deepWorkApps.contains { app.localizedCaseInsensitiveContains($0) }
    }

    /// True when the user is in a meeting app.
    var isInMeetingApp: Bool {
        guard let app = activeApp else { return false }
        let meetingApps = ["Zoom", "Teams", "FaceTime", "Google Meet", "Loom", "Around", "Webex"]
        return meetingApps.contains { app.localizedCaseInsensitiveContains($0) }
    }

    /// Returns an AttentionContext snapshot for the current world state.
    func attentionContext(
        timingEngine: ConversationalTimingEngine = .shared,
        recentInterruptionCount: Int = 0
    ) -> AttentionContext {
        var ctx = AttentionContext()
        ctx.isJarvisSpeaking = timingEngine.isTTSActive
        ctx.isUserSpeaking = timingEngine.isSpeechActive
        ctx.isListening = isInConversation
        ctx.currentApp = activeApp
        ctx.isInActiveMeeting = hasUpcomingMeeting && (minutesUntilNextMeeting ?? .max) <= 0
            || isInMeetingApp
        ctx.emotionalTone = emotionalTone
        ctx.secondsSinceLastConversation = secondsSinceLastInteraction
        ctx.secondsSinceLastInterruption = timingEngine.secondsSinceJarvisSpeech
        ctx.recentInterruptionCount = recentInterruptionCount
        ctx.conversationDepth = conversationDepth
        return ctx
    }

    // MARK: - Snapshot

    /// One-line summary for LLM context injection or diagnostics.
    var contextSummary: String {
        var parts: [String] = []
        if let app = activeApp { parts.append("app: \(app)") }
        if let proj = activeProject { parts.append("project: \(proj)") }
        if isMediaPlaying, let title = mediaTitle { parts.append("playing: \(title)") }
        if hasUpcomingMeeting, let min = minutesUntilNextMeeting {
            parts.append("meeting in \(min)min")
        }
        if emotionalTone != .neutral { parts.append("tone: \(emotionalTone)") }
        return parts.isEmpty ? "idle" : parts.joined(separator: ", ")
    }
}

// MARK: - WorldStateAggregator

/// Thin coordinator that wires existing service state into AmbientWorldState
/// so it stays up-to-date without each service needing to know about the model.
@MainActor
final class WorldStateAggregator {

    private weak var worldState: AmbientWorldState?
    private var tokens: [SystemBus.SubscriptionToken] = []

    init(worldState: AmbientWorldState = .shared) {
        self.worldState = worldState
        subscribeToSystemBus()
    }

    func update(from ambientEngine: AmbientContextEngine) {
        guard let ws = worldState else { return }
        let app = ambientEngine.context.activeApp
        ws.activeApp = app.name.isEmpty ? nil : app.name
        ws.activeWindowTitle = app.windowTitle.isEmpty ? nil : app.windowTitle
    }

    func update(isMediaPlaying: Bool, title: String? = nil, artist: String? = nil) {
        worldState?.isMediaPlaying = isMediaPlaying
        worldState?.mediaTitle = title
        worldState?.mediaArtist = artist
    }

    func update(haConnected: Bool, lastEvent: String? = nil) {
        worldState?.haConnected = haConnected
        if let e = lastEvent { worldState?.lastHAEvent = e }
    }

    func update(hasUpcomingMeeting: Bool, title: String? = nil, minutesUntil: Int? = nil) {
        worldState?.hasUpcomingMeeting = hasUpcomingMeeting
        worldState?.nextMeetingTitle = title
        worldState?.minutesUntilNextMeeting = minutesUntil
    }

    func update(isOnline: Bool) {
        worldState?.isOnline = isOnline
    }

    // MARK: - SystemBus subscriptions

    private func subscribeToSystemBus() {
        let bus = SystemBus.shared

        tokens.append(bus.subscribe(AppFocusChangedEvent.self) { [weak self] event in
            self?.worldState?.activeApp = event.activeApp
            self?.worldState?.activeWindowTitle = event.windowTitle
        })

        tokens.append(bus.subscribe(ConversationStartedEvent.self) { [weak self] _ in
            self?.worldState?.isInConversation = true
            self?.worldState?.secondsSinceLastInteraction = 0
        })

        tokens.append(bus.subscribe(ConversationEndedEvent.self) { [weak self] _ in
            self?.worldState?.isInConversation = false
        })

        tokens.append(bus.subscribe(SpeechCommandReceivedEvent.self) { [weak self] event in
            self?.worldState?.lastTranscript = event.transcript
            self?.worldState?.secondsSinceLastInteraction = 0
        })
    }

    // Tokens are released with the object; SystemBus cleans up via its weak map.
    // WorldStateAggregator is app-lifetime so explicit deinit cleanup isn't needed.
}
