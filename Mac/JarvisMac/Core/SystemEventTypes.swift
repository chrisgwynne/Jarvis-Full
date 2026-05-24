import Foundation

// MARK: - Base

/// Shared boilerplate for all concrete event structs.
struct SystemEventBase: Sendable {
    let id: UUID
    let timestamp: Date
    let correlationID: UUID?

    init(correlationID: UUID? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.correlationID = correlationID
    }
}

// MARK: - App Events

/// Frontmost application changed. Fires whenever the user switches apps.
struct AppFocusChangedEvent: SystemEvent {
    let base: SystemEventBase
    let previousApp: String
    let previousBundleID: String
    let activeApp: String
    let activeBundleID: String
    let windowTitle: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .ambient }
    var category: SystemEventCategory { .app }
    var priority: SystemEventPriority { .normal }

    init(previousApp: String, previousBundleID: String,
         activeApp: String, activeBundleID: String,
         windowTitle: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.previousApp = previousApp
        self.previousBundleID = previousBundleID
        self.activeApp = activeApp
        self.activeBundleID = activeBundleID
        self.windowTitle = windowTitle
    }
}

/// An application was launched.
struct AppLaunchedEvent: SystemEvent {
    let base: SystemEventBase
    let appName: String
    let bundleID: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .ambient }
    var category: SystemEventCategory { .app }
    var priority: SystemEventPriority { .low }

    init(appName: String, bundleID: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.appName = appName
        self.bundleID = bundleID
    }
}

/// An application terminated.
struct AppClosedEvent: SystemEvent {
    let base: SystemEventBase
    let appName: String
    let bundleID: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .ambient }
    var category: SystemEventCategory { .app }
    var priority: SystemEventPriority { .low }

    init(appName: String, bundleID: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.appName = appName
        self.bundleID = bundleID
    }
}

// MARK: - Screen Events

/// Semantic screen context was sampled and updated.
struct ScreenContextUpdatedEvent: SystemEvent {
    let base: SystemEventBase
    let summary: ScreenContextSummary

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .screen }
    var category: SystemEventCategory { .screen }
    var priority: SystemEventPriority { .low }

    init(summary: ScreenContextSummary, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.summary = summary
    }
}

/// An error, dialog, or build failure was detected on screen.
struct ScreenErrorDetectedEvent: SystemEvent {
    let base: SystemEventBase
    let appName: String
    let errorText: String
    let windowTitle: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .screen }
    var category: SystemEventCategory { .screen }
    var priority: SystemEventPriority { .high }

    init(appName: String, errorText: String, windowTitle: String,
         correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.appName = appName
        self.errorText = errorText
        self.windowTitle = windowTitle
    }
}

/// Privacy filter blocked context capture for a sensitive app.
struct ContextRedactedEvent: SystemEvent {
    let base: SystemEventBase
    let appName: String
    let bundleID: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .ambient }
    var category: SystemEventCategory { .privacy }
    var priority: SystemEventPriority { .low }

    init(appName: String, bundleID: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.appName = appName
        self.bundleID = bundleID
    }
}

// MARK: - Overlay Events

struct OverlayOpenedEvent: SystemEvent {
    let base: SystemEventBase
    let overlayKind: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .overlay }
    var category: SystemEventCategory { .overlay }
    var priority: SystemEventPriority { .low }

    init(overlayKind: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.overlayKind = overlayKind
    }
}

struct OverlayClosedEvent: SystemEvent {
    let base: SystemEventBase
    let overlayKind: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .overlay }
    var category: SystemEventCategory { .overlay }
    var priority: SystemEventPriority { .low }

    init(overlayKind: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.overlayKind = overlayKind
    }
}

// MARK: - Speech Events

struct SpeechCommandReceivedEvent: SystemEvent {
    let base: SystemEventBase
    let transcript: String
    let intent: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }

    init(transcript: String, intent: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.transcript = transcript
        self.intent = intent
    }
}

struct SpeechFollowUpReceivedEvent: SystemEvent {
    let base: SystemEventBase
    let transcript: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }

    init(transcript: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.transcript = transcript
    }
}

// MARK: - Memory Event

struct MemoryUpdatedEvent: SystemEvent {
    let base: SystemEventBase
    let entryID: String
    let tags: [String]

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .memory }
    var category: SystemEventCategory { .memory }
    var priority: SystemEventPriority { .low }

    init(entryID: String, tags: [String], correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.entryID = entryID
        self.tags = tags
    }
}

// MARK: - Proactivity Event

struct ProactiveSignalGeneratedEvent: SystemEvent {
    let base: SystemEventBase
    let signalSource: String
    let title: String
    let priority: SystemEventPriority

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .proactivity }
    var category: SystemEventCategory { .proactivity }

    init(signalSource: String, title: String,
         priority: SystemEventPriority = .normal, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.signalSource = signalSource
        self.title = title
        self.priority = priority
    }
}

// MARK: - Device Events

struct AndroidConnectedEvent: SystemEvent {
    let base: SystemEventBase
    let deviceName: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .android }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .normal }

    init(deviceName: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.deviceName = deviceName
    }
}

struct AndroidDisconnectedEvent: SystemEvent {
    let base: SystemEventBase
    let deviceName: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .android }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .normal }

    init(deviceName: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.deviceName = deviceName
    }
}

// MARK: - CI / GitHub Events

struct GitHubBuildFailedEvent: SystemEvent {
    let base: SystemEventBase
    let repo: String
    let branch: String
    let message: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .github }
    var category: SystemEventCategory { .ci }
    var priority: SystemEventPriority { .high }

    init(repo: String, branch: String, message: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.repo = repo
        self.branch = branch
        self.message = message
    }
}

// MARK: - System Health Events

struct SystemLowMemoryEvent: SystemEvent {
    let base: SystemEventBase
    let availableMB: Int

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .high }

    init(availableMB: Int, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.availableMB = availableMB
    }
}

struct SystemAudioErrorEvent: SystemEvent {
    let base: SystemEventBase
    let reason: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .system }
    var category: SystemEventCategory { .system }
    var priority: SystemEventPriority { .urgent }

    init(reason: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.reason = reason
    }
}

// MARK: - Conversation Events

/// Conversational window armed — user said the wake word; Jarvis is listening for follow-ups.
struct ConversationStartedEvent: SystemEvent {
    let base: SystemEventBase
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(correlationID: UUID? = nil) { self.base = SystemEventBase(correlationID: correlationID) }
}

/// Conversational session ended (permanent: user said "stop" / mic failure / 10-min timeout).
struct ConversationEndedEvent: SystemEvent {
    let base: SystemEventBase
    let permanent: Bool
    let reason: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(permanent: Bool, reason: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.permanent = permanent
        self.reason = reason
    }
}

/// Jarvis asked the user a question and is waiting for a follow-up reply.
struct ConversationFollowUpRequestedEvent: SystemEvent {
    let base: SystemEventBase
    let question: String
    let responseType: String   // "yesNo" | "clarification" | "freeform" | "choice"
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .high }
    init(question: String, responseType: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.question = question
        self.responseType = responseType
    }
}

/// The follow-up question was resolved (answered, timed out, or session ended).
struct ConversationFollowUpResolvedEvent: SystemEvent {
    let base: SystemEventBase
    let resolution: String   // "yes→speak" | "no→speak" | "llm" | "timeout" | "cleared"
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(resolution: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.resolution = resolution
    }
}

/// Jarvis is now in awaitingResponse state — waiting for the user's answer.
struct ConversationAwaitingResponseEvent: SystemEvent {
    let base: SystemEventBase
    let question: String
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .high }
    init(question: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.question = question
    }
}

/// Conversational window timed out due to silence.
struct ConversationTimedOutEvent: SystemEvent {
    let base: SystemEventBase
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .low }
    init(correlationID: UUID? = nil) { self.base = SystemEventBase(correlationID: correlationID) }
}

// MARK: - Audio Events

/// Wake word detected — user got Jarvis's attention.
struct WakeDetectedEvent: SystemEvent {
    let base: SystemEventBase
    let keyword: String
    let confidence: Double
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .high }
    init(keyword: String, confidence: Double, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.keyword = keyword
        self.confidence = confidence
    }
}

/// STT started — microphone is now listening for commands.
struct ListeningStartedEvent: SystemEvent {
    let base: SystemEventBase
    let reason: String   // "wakeWord" | "conversationalFollowup" | "pushToTalk"
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(reason: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.reason = reason
    }
}

/// STT stopped.
struct ListeningStoppedEvent: SystemEvent {
    let base: SystemEventBase
    let reason: String   // StopReason.rawValue
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .low }
    init(reason: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.reason = reason
    }
}

/// TTS started speaking.
struct TTSStartedEvent: SystemEvent {
    let base: SystemEventBase
    let textPreview: String   // first 80 chars
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(text: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.textPreview = String(text.prefix(80))
    }
}

/// TTS finished speaking.
struct TTSFinishedEvent: SystemEvent {
    let base: SystemEventBase
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .low }
    init(correlationID: UUID? = nil) { self.base = SystemEventBase(correlationID: correlationID) }
}

/// An intent was resolved from the user's transcript.
struct IntentResolvedEvent: SystemEvent {
    let base: SystemEventBase
    let transcript: String
    let intentLabel: String
    let resolvedBy: String   // "phraseStore" | "intentRouter" | "llm" | "followUp"
    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource   { .speech }
    var category: SystemEventCategory { .speech }
    var priority: SystemEventPriority { .normal }
    init(transcript: String, intentLabel: String, resolvedBy: String, correlationID: UUID? = nil) {
        self.base = SystemEventBase(correlationID: correlationID)
        self.transcript = transcript
        self.intentLabel = intentLabel
        self.resolvedBy = resolvedBy
    }
}

// MARK: - Home Assistant Camera Events

/// Motion or occupancy detected by a HA binary sensor.
/// Fires only on off → on transitions and only when a camera is linked.
struct HAMotionDetectedEvent: SystemEvent {
    let base: SystemEventBase
    let sensorEntityID: String
    let linkedCameraID: String?
    let isDoorbellEvent: Bool
    let alertPhrase: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .homeAssistant }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority {
        isDoorbellEvent ? .urgent : .high
    }

    init(sensorEntityID: String,
         linkedCameraID: String?,
         isDoorbellEvent: Bool,
         alertPhrase: String,
         correlationID: UUID? = nil) {
        self.base            = SystemEventBase(correlationID: correlationID)
        self.sensorEntityID  = sensorEntityID
        self.linkedCameraID  = linkedCameraID
        self.isDoorbellEvent = isDoorbellEvent
        self.alertPhrase     = alertPhrase
    }
}

/// A HA entity's state changed. Published for every state_changed WebSocket event
/// so the EventStore has a full audit trail.
struct HAEntityChangedEvent: SystemEvent {
    let base: SystemEventBase
    let entityID: String
    let newState: String
    let oldState: String?
    let domain: String

    var id: UUID             { base.id }
    var timestamp: Date      { base.timestamp }
    var correlationID: UUID? { base.correlationID }
    var source: SystemEventSource    { .homeAssistant }
    var category: SystemEventCategory { .device }
    var priority: SystemEventPriority { .low }

    init(entityID: String, newState: String, oldState: String?,
         correlationID: UUID? = nil) {
        self.base     = SystemEventBase(correlationID: correlationID)
        self.entityID = entityID
        self.newState = newState
        self.oldState = oldState
        self.domain   = entityID.split(separator: ".").first.map(String.init) ?? "unknown"
    }
}
