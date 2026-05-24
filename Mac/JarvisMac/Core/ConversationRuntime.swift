import Foundation

// MARK: - ConversationRuntime

/// Owns the conversation state machine: armed window, session lifecycle,
/// pending question context, and related timers.
///
/// JarvisController holds a reference to this and delegates conversation-specific
/// timer/state management to it. ConversationRuntime publishes SystemBus events
/// at every state transition so other runtimes (ProactivityEngine, EventStore,
/// debug overlays) can react without direct coupling.
@MainActor
final class ConversationRuntime: RuntimeSubsystem {

    // MARK: - RuntimeSubsystem

    let id = "conversation"
    let displayName = "Conversation Runtime"
    let startupOrder = 40
    private(set) var state: RuntimeState = .stopped

    // MARK: - Conversation state

    /// True for 10 minutes after the last wake event — follow-ups don't need wake word.
    private(set) var isArmed: Bool = false
    /// True while STT is cycling in persistent-conversation mode.
    private(set) var isSessionActive: Bool = false
    /// The pending question Jarvis asked, waiting for a user reply.
    private(set) var pendingContext: PendingConversationContext?

    // Timers owned by this runtime (not JarvisController)
    private var armTask: Task<Void, Never>?
    private var conversationalTimeoutTask: Task<Void, Never>?
    private var awaitingResponseTimeoutTask: Task<Void, Never>?
    /// P0: track the deferred STT-restart task in endSession() so stop() can cancel it.
    private var restartListeningTask: Task<Void, Never>?

    // MARK: - Injected audio callbacks
    // Set by JarvisController during bootstrap. ConversationRuntime calls these
    // instead of directly calling audio services — keeps the dependency direction correct.

    var onStartListening: (() -> Void)?
    var onStopListening: ((StopReason) -> Void)?
    var onReturnToPassiveWake: ((StopReason) -> Void)?

    // MARK: - Injected state readers
    // These closures avoid ConversationRuntime needing a direct reference to JarvisController.

    var isListening: (() -> Bool) = { false }
    var isSpeaking: (() -> Bool) = { false }
    var listeningEnabled: (() -> Bool) = { true }
    var mediaIsPlaying: (() -> Bool) = { false }
    var conversationalTimeoutSeconds: (() -> Double) = { 8.0 }
    var followUpEnabled: (() -> Bool) = { true }
    var persistentConversationEnabled: (() -> Bool) = { true }

    // MARK: - Diagnostics

    private(set) var sessionCount: Int = 0
    private(set) var followUpCount: Int = 0
    private(set) var timeoutCount: Int = 0
    private(set) var lastSessionStartedAt: Date? = nil
    private(set) var lastEventName: String = "—"

    // MARK: - RuntimeSubsystem lifecycle

    func start() async throws {
        state = .running
        Log.runtime.info("[ConversationRuntime] started")
    }

    func stop() async {
        armTask?.cancel(); armTask = nil
        conversationalTimeoutTask?.cancel(); conversationalTimeoutTask = nil
        awaitingResponseTimeoutTask?.cancel(); awaitingResponseTimeoutTask = nil
        restartListeningTask?.cancel(); restartListeningTask = nil  // P0: cancel deferred restart
        isArmed = false
        isSessionActive = false
        pendingContext = nil
        state = .stopped
        Log.runtime.info("[ConversationRuntime] stopped")
    }

    func healthCheck() async -> HealthStatus {
        if state == .stopped { return .degraded("Not started") }
        return .healthy
    }

    // MARK: - Arm / disarm

    /// Arm the 10-minute conversational window from now.
    /// Cancels any previous arm timer.
    func arm() {
        isArmed = true
        isSessionActive = true
        sessionCount += 1
        lastSessionStartedAt = Date()
        lastEventName = "armed"

        armTask?.cancel()
        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isArmed = false
            self.isSessionActive = false
            self.lastEventName = "arm_expired"
            SystemBus.shared.publish(ConversationEndedEvent(permanent: false, reason: "10_min_timeout"))
            Log.runtime.info("[ConversationRuntime] 10-min armed window expired")
        }

        SystemBus.shared.publish(ConversationStartedEvent(correlationID: ExecutionTracer.shared.activeCorrelationID))
        Log.runtime.info("[ConversationRuntime] armed (session \(self.sessionCount))")
    }

    /// Reset the 10-minute armed window (called on each transcript while armed).
    func resetArm() {
        guard isArmed else { return }
        arm()
    }

    // MARK: - Conversational listening

    /// Start a conversational STT window (no wake word required).
    /// Suppressed during media playback.
    func startConversationalListening() {
        guard !isListening() else { return }
        guard !mediaIsPlaying() else {
            Log.runtime.info("[ConversationRuntime] conv_start suppressed: media playing")
            return
        }
        onStartListening?()
        scheduleTimeout()
        lastEventName = "listening_started"
        Log.runtime.info("[ConversationRuntime] conversational window opened")
    }

    // MARK: - Timeout management

    func scheduleTimeout() {
        conversationalTimeoutTask?.cancel()
        let seconds = conversationalTimeoutSeconds()
        conversationalTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.endSession(permanent: false)
        }
    }

    func cancelTimeout() {
        conversationalTimeoutTask?.cancel()
        conversationalTimeoutTask = nil
    }

    // MARK: - Session end

    func endSession(permanent: Bool, reason: String = "silence_timeout") {
        cancelTimeout()
        lastEventName = permanent ? "session_ended" : "silence_timeout"

        if permanent {
            isSessionActive = false
            onStopListening?(.userCancelled)
            SystemBus.shared.publish(ConversationEndedEvent(permanent: true, reason: reason))
            Log.runtime.info("[ConversationRuntime] session ended permanently: \(reason)")
            return
        }

        // Silence timeout — decide whether to restart or return to wake.
        onStopListening?(.silenceTimeout)
        timeoutCount += 1
        SystemBus.shared.publish(ConversationTimedOutEvent())

        guard isArmed,
              followUpEnabled(),
              persistentConversationEnabled(),
              listeningEnabled(),
              !isSpeaking() else {
            isSessionActive = false
            onReturnToPassiveWake?(.silenceTimeout)
            lastEventName = "returned_to_wake"
            Log.runtime.info("[ConversationRuntime] returned to passive wake")
            return
        }

        // Restart STT after 150ms settle.
        // P0: store the task so stop() can cancel it — prevents a zombie restart
        // firing after the runtime has been torn down.
        Log.runtime.info("[ConversationRuntime] silence timeout — restarting STT (persistent)")
        restartListeningTask?.cancel()
        restartListeningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.isArmed, !self.isListening() else { return }
            self.restartListeningTask = nil
            self.startConversationalListening()
        }
    }

    // MARK: - Pending context

    /// Set a pending question context. Publishes events so ProactivityEngine can pause.
    func setPendingContext(_ context: PendingConversationContext) {
        pendingContext = context
        followUpCount += 1
        lastEventName = "follow_up_requested"
        SystemBus.shared.publish(ConversationFollowUpRequestedEvent(
            question: context.assistantQuestion,
            responseType: context.expectedResponseType.rawValue,
            correlationID: ExecutionTracer.shared.activeCorrelationID
        ))
        SystemBus.shared.publish(ConversationAwaitingResponseEvent(
            question: context.assistantQuestion,
            correlationID: ExecutionTracer.shared.activeCorrelationID
        ))
        scheduleAwaitingResponseTimeout()
        Log.runtime.info("[ConversationRuntime] pending context set: \(context.assistantQuestion.prefix(60))")
    }

    func clearPendingContext(resolution: String) {
        guard pendingContext != nil else { return }
        pendingContext = nil
        awaitingResponseTimeoutTask?.cancel()
        awaitingResponseTimeoutTask = nil
        lastEventName = "follow_up_resolved:\(resolution)"
        SystemBus.shared.publish(ConversationFollowUpResolvedEvent(
            resolution: resolution,
            correlationID: ExecutionTracer.shared.activeCorrelationID
        ))
        Log.runtime.info("[ConversationRuntime] pending context cleared: \(resolution)")
    }

    private func scheduleAwaitingResponseTimeout() {
        awaitingResponseTimeoutTask?.cancel()
        awaitingResponseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000) // 20s
            guard let self, !Task.isCancelled else { return }
            guard self.pendingContext != nil else { return }
            Log.runtime.info("[ConversationRuntime] awaiting response timed out")
            self.clearPendingContext(resolution: "timeout")
            if !self.isArmed {
                self.onReturnToPassiveWake?(.silenceTimeout)
            }
        }
    }
}
