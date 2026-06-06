import Foundation
import SwiftUI

// MARK: - Device & service status

enum DeviceStatus: Equatable {
    case unknown
    case ready
    case unavailable(String)
    case denied
    case failed(String)

    var label: String {
        switch self {
        case .unknown: return "…"
        case .ready: return "Ready"
        case .unavailable(let why): return why
        case .denied: return "Denied"
        case .failed(let why): return why
        }
    }

    var isHealthy: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Engine selection (user-pickable)

enum SpeechEngine: String, Codable, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apple:   return "Apple Speech"
        case .whisper: return "Whisper (local)"
        }
    }
}

/// How Jarvis speaks back. Separate from how it listens (SpeechEngine).
enum TTSEngine: String, Codable, CaseIterable, Identifiable {
    case appleSystem
    case piper

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleSystem: return "Apple System Voice"
        case .piper:       return "Piper ONNX Voice"
        }
    }
}

// MARK: - Assistant lifecycle states (drives orb + UI)

enum AssistantPhase: String, Codable, Equatable {
    case idle                    // pre-bootstrap only; never the resting state
    case wakeListening           // passive wake-word listening (resting state)
    case listening               // active command STT (wake-triggered or PTT)
    case conversationalListening // follow-up STT after TTS (no pending question)
    case awaitingResponse        // Jarvis asked a question; listening for the answer
    case thinking                // routing / executing
    case speaking                // TTS active
    case bargedIn                // user interrupted TTS
    case muted                   // user explicitly disabled listening
    case error                   // STT/audio failure — shows lastError in UI
}

// MARK: - UI display mode

enum UIMode: String, Equatable, CaseIterable {
    case orb        // orb-first fullscreen (default)
    case dashboard  // workspace widget grid
    case developer  // developer diagnostics grid
}

// MARK: - Operating mode

/// Lightweight voice/behaviour modes selectable by voice command or settings.
enum OperatingMode: String, Codable, CaseIterable, Identifiable {
    case normal   // default — full TTS + standard responses
    case concise  // shorter responses (maps to .minimal response style)
    case silent   // no TTS unless critical; overlay/text only
    case ambient  // proactive subtle updates enabled; no interruptions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal:   return "Normal"
        case .concise:  return "Concise"
        case .silent:   return "Silent"
        case .ambient:  return "Ambient"
        }
    }

    var symbol: String {
        switch self {
        case .normal:   return "speaker.wave.2.fill"
        case .concise:  return "text.alignleft"
        case .silent:   return "speaker.slash.fill"
        case .ambient:  return "waveform.path.ecg"
        }
    }

    /// Whether TTS is suppressed (only critical notifications speak).
    var suppressesTTS: Bool { self == .silent }

    /// Whether response style should be forced to minimal.
    var forcesConcise: Bool { self == .concise || self == .ambient }
}

// MARK: - AssistantPhase view helpers

extension AssistantPhase {
    var accentColor: Color {
        switch self {
        case .idle:                    return .gray
        case .wakeListening:           return .blue
        case .listening:               return .cyan
        case .conversationalListening: return .green
        case .awaitingResponse:        return .green
        case .thinking:                return .purple
        case .speaking:                return .orange
        case .bargedIn:                return .orange
        case .muted:                   return .gray
        case .error:                   return .red
        }
    }

    var shortLabel: String {
        switch self {
        case .idle:                    return "IDLE"
        case .wakeListening:           return "PASSIVE"
        case .listening:               return "LISTENING"
        case .conversationalListening: return "FOLLOW-UP"
        case .awaitingResponse:        return "AWAITING"
        case .thinking:                return "THINKING"
        case .speaking:                return "SPEAKING"
        case .bargedIn:                return "INTERRUPTED"
        case .muted:                   return "MUTED"
        case .error:                   return "ERROR"
        }
    }
}

// MARK: - Local intents

/// All the things the local intent router can produce. Anything not matched
/// falls through to `.unknown` so a future LLM phase can take over.
enum Intent: Equatable {
    case showCommandCentre
    case hideCommandCentre
    case toggleCommandCentre
    case whatCanYouSee
    case describePerson    // "describe the person" — LLM person description
    case whatIsOnDesk      // "what's on my desk" — LLM object/desk description
    case readThis
    case isAnyoneThere
    case watchTheDesk
    case watchRoom
    case stopWatchingCamera
    case lookAtThis
    case scanThis
    case whatAmIHolding  // "what am I holding?" — detectHeldObject mode
    case takePhoto
    case openApp(name: String)
    case openAppOnPhone(name: String)
    case openURL(URL)
    case stopTalking
    case status
    case useMicrophone(name: String?)
    case useCamera(name: String?)
    case homeStatus
    case homeTurnOn(entity: String)
    case homeTurnOff(entity: String)
    case homeQueryEntity(entity: String)
    case homeSetBrightness(entity: String, level: Int)  // 0-100
    case homeSetColor(entity: String, color: String)
    case homeActivateScene(name: String)
    case homeOpenCover(entity: String)
    case homeCloseCover(entity: String)
    case homeLock(entity: String)
    case homeUnlock(entity: String)
    case homeShowCamera(entity: String)
    case homeShowCameraOverlay(entity: String)  // explicit overlay route (phrase-driven)
    case homeCloseCamera                         // close the .haCamera overlay
    case homeShowAllCameras                      // open grid view of all cameras
    case homeMuteAlerts                          // mute HA proactive alerts for 1 hour
    case homeUnmuteAlerts                        // unmute HA proactive alerts
    case homeIgnoreCameraForHour(entity: String) // suppress one camera's alerts for 1 hour
    case homeShowHADiagnostics                   // open HA diagnostics overlay
    case homeRunAutomation(name: String)
    // Calendar
    case showCalendar
    case nextMeeting
    case meetingsToday
    case addReminder(text: String)
    // Todoist
    case showTasks
    case whatAreMyTasks
    case overdueTasks
    case addTask(text: String)
    case completeTask(text: String)
    case continueFromAndroid
    case showContext
    // Session / context
    case repeatLast
    // UI mode
    case focusMode
    case dashboardMode
    // Overlay skeleton
    case showTestOverlay
    case closeOverlay
    case maximizeOverlay
    case minimizeOverlay
    case pinOverlay    // "pin this" — survives voice close commands
    case unpinOverlay  // "unpin this"
    case overlayResetLayout   // "reset layout" — clears all manual frames
    case overlayFocusTop      // "focus that" / "bring to front"
    // Chat overlay
    case showChat
    // Debug HUD
    case showDebugHUD
    case hideDebugHUD
    // Identity / personal facts — spoken answers, no overlay
    case askMyName           // "what is my name" / "who am I"
    case askAssistantName    // "what's your name" / "who are you"
    case askPersonalFacts    // "what do you know about me" / "tell me what you know"
    // Memory — explicit storage
    case rememberThis(text: String)
    case rememberLast              // "remember that" / "save that" — stores last response
    case searchMemory(query: String)
    case searchAgain               // repeat last search
    case whatDoYouRemember         // "what do you remember" — speaks list, no overlay
    case showRecentMemories
    // Context / activity recall
    case whatWasIDoingEarlier
    case showRecentActivity
    // Screen awareness
    case whatAmILookingAt
    case readMyScreen
    case summariseScreen
    case captureScreen
    case watchThisScreen
    case stopWatchingScreen
    case whatAppAmIUsing
    case whatTextDoYouSee
    // Ambient context
    case whatAmIWorkingOn         // "what am I working on" — speaks AmbientContext summary
    case whatChangedOnScreen      // "what changed" — delta from last summary
    case whatFailedOnScreen       // "what failed" / "what's the error"
    case showAmbientContextOverlay   // debug overlay
    case showRuntimeDiagnostics      // RuntimeCoordinator health overlay
    case showSpeechLatency           // speech-to-speech latency diagnostics
    case showVoiceLab                // TTS backend comparison + benchmarking
    case showSpatialInteraction      // "spatial mode" — hand tracking overlay
    case hideSpatialInteraction      // "close spatial" — dismiss overlay
    case enableAmbientContext     // "start ambient context" / "enable background awareness"
    case disableAmbientContext    // "pause ambient context"
    case watchThis                // "watch this" / "monitor this" — boost sampling frequency
    case stopWatching             // "stop watching" / "stop monitoring"
    // Overlay kinds
    case showMemoryOverlay
    case showScreenOverlay
    case showCameraOverlay
    case showCalendarOverlay
    case showTasksOverlay
    case showHomeOverlay
    // Response playbook
    case showResponsePlaybook

    // Personality
    case showPersonalitySettings
    case reloadPersonality

    // Operating modes
    case modeNormal
    case modeConcise
    case modeSilent
    case modeAmbient

    // Timeline
    case showTimeline
    case whatDidIDoToday

    // Reasoning / debug
    case showReasoning
    case whyDidYouDoThat

    // Attention / context
    case showAttentionState
    case showEntityGraph

    // News
    case showNews
    case showNewsLabel(label: String)
    case searchNews(query: String)
    case refreshNews
    case watchFeed(name: String)
    case stopWatchingNews
    case saveNewsArticle
    case showSavedNews

    // News — live video / channel control
    case watchNews                              // open + play default channel
    case watchNewsChannel(name: String)         // "watch Bloomberg"
    case nextNewsChannel
    case prevNewsChannel
    case summariseNews                          // explicit headline summary
    case openStoryAt(index: Int)                // "open story one"
    case summariseStoryAt(index: Int)           // "summarise story two"
    case openInBrowser                          // open active article externally

    // Small talk / sanity-check commands — proof routing works.
    case canYouHearMe
    case areYouListening
    case farewell      // goodbye, bye, see you, good night
    case thankUser     // thanks, thank you
    case tellTime
    case tellDate   // "what's the date", "what day is it"

    // Developer UI mode
    case developerMode     // "developer mode" / "show diagnostics"
    case workspaceMode     // "workspace mode" / "open workspace"

    // Proactivity / notifications
    case showNotifications    // "what needs my attention" / "show notifications"
    case dismissNotifications // "clear notifications" / "dismiss all"
    case pauseProactivity     // "pause proactivity"
    case resumeProactivity    // "resume proactivity"
    case muteNewsForHour      // "mute news for an hour"
    case muteNews             // "mute news"
    case unmuteNews           // "unmute news"
    case openThatStory        // "open that story" / "open the article"
    case summariseThat        // "summarise that" / "summarise the story"
    case showLatestAlert      // "show me" / "open that" / "what was that"
    case dismissLatestAlert   // "dismiss that" / "never mind"
    case proactivityUseful    // "useful" / "that was useful" — positive feedback
    case proactivityNotUseful // "not useful" / "not helpful" — negative feedback
    case neverTellMeAboutThis // "don't tell me about this" — suppress story type
    case alwaysTellMeAboutThis// "always tell me about this" — boost story type

    case hideCamera
    case hideNews
    case hideArticle

    // Always-on listening lifecycle
    case disableListening    // "stop listening" / "go quiet" / "sleep"
    case enableListening     // "start listening" / "wake up" / "resume"

    // MARK: - macOS System Control

    /// Open System Settings, optionally to a named pane (wifi, bluetooth, sound…)
    case openSystemSettings(pane: String?)
    /// Volume controls
    case volumeUp
    case volumeDown
    case mute
    case unmute
    case setVolume(level: Int)
    case getVolume
    /// File / folder operations
    case openFolder(name: String)
    case openLatestDownload
    case findFile(query: String)
    case revealInFinder(path: String)
    /// App management (beyond generic openApp)
    case activateApp(name: String)   // bring running app to front
    case hideApp(name: String)
    case quitApp(name: String)
    case listRunningApps
    /// Window / desktop controls
    case showDesktop
    case lockScreen
    case sleepDisplay

    // Connectivity toggles
    case wifiOn
    case wifiOff
    case bluetoothOn
    case bluetoothOff

    // Weather
    case currentWeather
    case weatherForecast(days: Int)

    // GitHub (basic)
    case checkGitHub
    case showGitHubOverlay

    // GitHub Intelligence
    case githubListPRs(repo: String?)
    case githubReviewPR(repo: String?, number: Int?)
    case githubOpenPR(repo: String?)
    case githubStalePRs(repo: String?)
    case githubListIssues(repo: String?)
    case githubStaleIssues(repo: String?)
    case githubCreateIssue(repo: String?, title: String?)
    case githubRecentCommits(repo: String?)
    case githubChangesToday(repo: String?)
    case githubChangesSince(repo: String?, days: Int)
    case githubCheckCI(repo: String?)
    case githubListMyRepos
    case githubActiveRepos
    case githubNeglectedRepos
    case githubCreateRepo(name: String?)
    case githubDescribeRepo(repo: String?)
    case githubProjectStatus(repo: String?)
    case githubCodeReview(repo: String?)
    case githubSummariseDiff(repo: String?)
    case githubLocalStats(repo: String?)
    case githubDashboard
    /// Opens the GitHub Issue Overlay (reviewable — never silently creates).
    /// If `withContext: true`, pre-fills from the most recent error/command context.
    case openGitHubIssueOverlay(withContext: Bool)

    // Stability / watchdog
    /// Open a manual stability / crash diagnostic report.
    case runStabilityReport
    /// Speak the current top CPU suspect and open the diagnostics overlay.
    case whyAreYouCrashing
    /// Open the crash breadcrumb log in Console / Finder.
    case openCrashLog
    /// Enter safe degraded mode immediately.
    case enterSafeMode

    // Shopify
    case shopifyOrders
    case shopifyFulfilment
    case shopifyRevenue
    case shopifyStatus
    case showShopifyOverlay

    // Obsidian
    case showObsidianOverlay
    case searchObsidian(query: String)
    case openObsidianNote(query: String)
    case readObsidianNote(query: String)
    case createObsidianNote(title: String, content: String)
    case appendToObsidianNote(title: String, content: String)
    case recentObsidianNotes
    case obsidianNotesTagged(tag: String)
    case whatDoIKnowAbout(topic: String)

    // Apple Notes (Sprint X)
    case createNote(title: String, body: String)
    case appendNote(title: String, body: String)
    case searchNotes(query: String)
    case openNotes
    case showNotes

    // Email / Apple Mail (Sprint AA)
    case checkEmail
    case unreadEmail
    case readLatestEmail
    case searchEmail(query: String)
    case summariseEmail
    case draftEmail(to: String, subject: String, body: String)
    case replyEmail(to: String, body: String)
    case showEmail
    case importantEmail

    // Help / capabilities
    case jarvisHelp

    // Daily briefing
    case dailyBriefing

    // MARK: - Timers & Stopwatch
    case setTimer(seconds: TimeInterval, name: String?)
    case cancelTimer(name: String?)
    case cancelAllTimers
    case timerStatus
    case startStopwatch
    case stopStopwatch
    case stopwatchStatus

    // MARK: - Clipboard
    case clipboardRead
    case clipboardCopy

    // MARK: - Spotify
    case spotifyPlay(query: String?)
    case spotifyPause
    case spotifyResume
    case spotifyNext
    case spotifyPrevious
    case spotifyWhatIsPlaying
    case spotifyVolume(percent: Int)
    case spotifyShuffle(on: Bool)

    // MARK: - Android Bridge (Mac → Phone)
    case callContact(name: String)
    case sendSMS(recipient: String, message: String)
    case sendWhatsApp(recipient: String, message: String)
    case findContact(query: String)
    case ringPhone
    case phoneLocation
    case startNavigation(destination: String)
    case readNotifications
    case queryNotification(app: String)
    case showAndroidOverlay
    case androidBridgeStatus
    /// Phone battery level + charging state — answered directly from the
    /// latest heartbeat cache, no LLM, no network.
    case phoneBattery
    case capturePhoneCamera

    // Android phone events — context-aware follow-up actions
    /// "Call him back", "return the call" — resolved from latest missed/incoming caller.
    case callBackLastCaller
    /// "Reply saying I'm busy" — resolved from latest SMS or WhatsApp sender.
    case replyToLastSender(message: String)
    /// "What did she say", "show me the message" — opens android overlay to latest message.
    case showLatestAndroidMessage

    // Phase-1 remote call control
    /// "Answer it" — tells Android to accept the ringing call.
    case answerCall
    /// "Decline it" / "reject it" — tells Android to reject the ringing call.
    case declineCall
    /// "Hang up" / "end the call" — tells Android to terminate the active call.
    case hangUpCall
    /// "Put it on speaker" — routes Android call audio to speakerphone.
    case speakerOn
    /// "Turn speaker off" — routes Android call audio off speakerphone.
    case speakerOff

    // WhatsApp calls — parameterised by contact name, resolved on Android.
    /// "Call Mike on WhatsApp" / "phone Cath on WhatsApp" / "ring Rob on WhatsApp".
    case whatsAppVoiceCall(contact: String)
    /// "Video call Cath on WhatsApp" / "WhatsApp video call Mike".
    case whatsAppVideoCall(contact: String)

    // Living documentation / help
    /// "show help", "what can you do", "teach me Jarvis" — opens the help overlay
    /// and speaks a short summary of the highest-priority section.
    case showHelp
    /// "how do I call someone", "help me with vision" — runs `query` through
    /// `LivingDocumentationEngine.answer(for:)` and speaks the answer.
    case documentationLookup(query: String)

    // MARK: - Reddit
    /// "show Reddit" / "open Reddit" — opens the Reddit overlay in feed mode.
    case showReddit
    /// "show top Reddits" / "show top Reddit posts" — opens the overlay
    /// sorted by score across every enabled source.
    case showRedditTop
    /// "show r/technology" / "open LocalLLaMA" — opens the overlay scoped
    /// to one subreddit (matched against the configured source list).
    case showSubreddit(name: String)
    /// "what are people saying about X" / "search Reddit for X" — runs a
    /// search across every enabled source, opens the overlay in
    /// search-results mode.
    case redditQuery(query: String)
    /// "summarise this post" — LLM-summarises the active post's body.
    case redditSummarisePost
    /// "summarise the comments" / "what are the comments saying" —
    /// LLM-summarises the comment thread of the active post.
    case redditSummariseComments
    /// "open the first one" / "open the second Reddit post" — index is
    /// 0-based; resolves against the currently displayed list.
    case redditOpenIndex(index: Int)
    /// "show comments" / "load comments" — loads and displays the
    /// comment tree for the currently-active Reddit post.
    case redditShowComments
    /// "open in browser" — opens the active post's URL in Safari.
    case redditOpenInBrowser
    /// "save that" — toggles `savedPostIds` on the active post.
    case redditSavePost
    /// "refresh Reddit" — triggers `RedditStore.refreshAllEnabledSources()`.
    case redditRefresh

    // MARK: - Visual Intelligence / POI Surveillance (Sprint L)
    /// "show surveillance" / "show cameras" / "surveillance mode"
    case showSurveillanceMode
    /// "hide surveillance" / "close cameras"
    case hideSurveillanceMode
    /// "start surveillance" — activates VisionModule detection pipeline
    case startSurveillance
    /// "stop surveillance" — deactivates VisionModule
    case stopSurveillance
    /// "what do you see" / "describe the scene" — spoken scene description
    case describeVisualScene
    /// "who is at the door" / "anything outside"
    case whoIsAtLocation(location: String)
    /// "any people outside" / "any motion detected"
    case anyPeopleDetected
    /// "show driveway camera" / "show front door" — focus one named feed
    case focusCamera(name: String)
    /// "add RTSP feed" / "add camera rtsp://..."
    case addRTSPCamera(name: String, url: String)
    /// "what moved" / "last motion event"
    case lastMotionEvent
    /// "show threat status" / "threat report"
    case showThreatStatus
    /// "track that" — activate high-frequency tracking on current scene
    case activateThreatTracking

    // MARK: - Spatial Interaction Phase 1 (Sprint M)
    /// "save this as my code workspace"
    case saveWorkspace(name: String)
    /// "restore my code workspace"
    case restoreWorkspace(name: String)
    /// "show my workspaces" / "list workspaces"
    case listWorkspaces
    /// "move that left" — nudge hovered widget leftward
    case moveWidgetLeft
    /// "move that right"
    case moveWidgetRight
    /// "move that up"
    case moveWidgetUp
    /// "move that down"
    case moveWidgetDown
    /// "make this bigger" / "expand that"
    case resizeWidgetLarge
    /// "make this smaller" / "shrink that"
    case resizeWidgetSmall
    /// "minimize this" / "collapse that"
    case minimizeWidget
    /// "dock this to the left" — dock hovered widget to a screen edge
    case dockWidget(edge: String)
    /// "snap this to top left" — snap hovered widget to a named zone
    case snapWidget(zone: String)
    /// "show spatial debug" / "spatial diagnostics"
    case showSpatialDebug
    /// "snap Finder to the left" — native window management
    case snapWindowLeft(appName: String)
    /// "snap Safari to the right"
    case snapWindowRight(appName: String)
    /// "tile my windows"
    case tileWindows
    /// "focus VS Code" / "switch to Xcode"
    case focusWindow(appName: String)

    // MARK: - Conversational Jarvis (Sprint K)
    /// "log that as done" / "mark that as complete" — save last activity to project memory
    case logProgressNote(text: String)
    /// "log that" / "save that to the roadmap" — general save-last-context
    case saveToProjectMemory
    /// "what did I build today" / "what did I work on" — query project memory
    case queryProjectMemory(query: String)
    /// "show today's Jarvis log" — open daily Obsidian note
    case showTodayJarvisLog
    /// "stop logging" — pause memory auto-save for this session
    case pauseMemoryLogging
    /// "start logging again" — resume memory auto-save
    case resumeMemoryLogging
    /// "do not save this" — mark current turn ephemeral
    case doNotSaveThis
    /// "show project status" / "what's our project status"
    case showProjectStatus
    /// "what have I built" / "what's been done"
    case whatHaveIBuilt
    /// "what's missing" / "what's left to build"
    case whatIsMissing
    /// "show routing diagnostics" — show ConversationRouter debug info
    case showRoutingDiagnostics

    // MARK: - Focus Awareness (Sprint W)
    /// "show focus" / "show context graph" — opens runtime diagnostics with focus state + speaks summary
    case showFocus
    /// "explain current focus" / "why do you think that" — speaks graph-inferred project provenance
    case explainCurrentFocus

    // MARK: - Brain
    /// "show brain" / "open brain overlay" — opens Brain memory + episode browser
    case showBrainOverlay
    /// "brain summary" / "what do you remember today" — today's episode digest
    case brainSummaryToday
    /// "brain week" / "what have you learned this week" — weekly memory summary
    case brainSummaryWeek

    // MARK: - Games
    /// "play ping pong" / "ping pong" — hand-tracked ping pong game overlay
    case playPingPong

    // Unknown
    case unknown(String)
}

// MARK: - Chat

enum ChatRole: Equatable {
    case user, assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let timestamp: Date
    var isLive: Bool

    init(role: ChatRole, text: String, timestamp: Date = Date(), isLive: Bool = false) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isLive = isLive
    }
}

// MARK: - Listening session

/// Tracks a single listening window across one OR MORE STT recognizer
/// restarts. Wake-word sessions need a protected window during which
/// empty/error finals are treated as transient and trigger a session
/// restart rather than dropping to idle.
///
/// Reference type on purpose: observation flags (audio buffer seen, etc.)
/// are mutated from the recognizer callback closures and the @MainActor
/// listening task, and we want everyone to see the same state without
/// copy-on-write or @Sendable dances.
final class ListeningSession: Identifiable, Equatable {
    enum Reason: String {
        case pushToTalk             = "push_to_talk"
        case wakeWord               = "wake_word"
        case conversationalFollowup = "conversational_followup"

        /// Minimum seconds before silence may close the session.
        var minimumListenSeconds: TimeInterval {
            switch self {
            case .pushToTalk:             return 0.5
            case .wakeWord:               return 5.0
            case .conversationalFollowup: return 4.0
            }
        }

        /// Window in which empty `isFinal` must be ignored (and the session
        /// restarted) instead of closing listening.
        var allowEmptyFinalAfterSeconds: TimeInterval { minimumListenSeconds }

        /// Window in which a "no speech / recognizer error" must restart
        /// rather than drop to idle.
        var allowSilenceTimeoutAfterSeconds: TimeInterval { minimumListenSeconds }
    }

    let id: UUID
    let reason: Reason
    let startedAt: Date
    let minimumListenUntil: Date
    let allowEmptyFinalAfter: Date
    let allowSilenceTimeoutAfter: Date

    // Observation flags — set as the session progresses across one or more
    // recognizer restarts. Read after the recognizer stream ends to decide
    // whether to restart within the protected window or drop to idle.
    var hasReceivedAudioBuffer: Bool = false
    var hasReceivedPartialTranscript: Bool = false
    var hasReceivedNonEmptyFinal: Bool = false
    var isCancelled: Bool = false
    var restartCount: Int = 0
    var lastStopReason: StopReason = .unknown

    init(id: UUID, reason: Reason, startedAt: Date) {
        self.id = id
        self.reason = reason
        self.startedAt = startedAt
        self.minimumListenUntil = startedAt.addingTimeInterval(reason.minimumListenSeconds)
        self.allowEmptyFinalAfter = startedAt.addingTimeInterval(reason.allowEmptyFinalAfterSeconds)
        self.allowSilenceTimeoutAfter = startedAt.addingTimeInterval(reason.allowSilenceTimeoutAfterSeconds)
    }

    static func make(reason: Reason) -> ListeningSession {
        ListeningSession(id: UUID(), reason: reason, startedAt: Date())
    }

    static func == (lhs: ListeningSession, rhs: ListeningSession) -> Bool {
        lhs.id == rhs.id
    }

    var shortID: String { String(id.uuidString.prefix(8)) }

    var minListenRemainingSeconds: TimeInterval {
        max(0, minimumListenUntil.timeIntervalSinceNow)
    }
}

// MARK: - Listening lifecycle coordinator types

/// The desired macro-level listening mode for the assistant.
/// Set by user preference and never overridden by overlays or commands.
enum ListeningMode: String, Equatable {
    /// All listening is disabled (user said "stop listening" / muted).
    case disabled
    /// Only the wake-word engine runs. STT fires only on a confirmed wake event.
    case wakeWordOnly
    /// Wake word fires STT; after each interaction the 10-minute conversational
    /// window keeps STT running without needing "Jarvis" again.
    case persistent
    /// Full persistent mode AND follow-up context tracking is active.
    case conversation

    var displayName: String {
        switch self {
        case .disabled:    return "Disabled"
        case .wakeWordOnly: return "Wake word only"
        case .persistent:  return "Persistent"
        case .conversation: return "Conversation"
        }
    }
}

/// The actual instantaneous listening state — what the audio pipeline is doing
/// right now. Distinct from `ListeningMode` which is the *desired* state.
enum ListeningState: Equatable {
    /// Microphone/speech permission unavailable.
    case unavailable(reason: String)
    /// Listening is enabled but nothing is actively listening (pre-boot).
    case idleListening
    /// Wake-word engine is armed and waiting for "Jarvis".
    case wakeWordListening
    /// STT engine is running and transcribing.
    case activelyListening
    /// Transcript received, routing to intent.
    case processing
    /// TTS is playing.
    case speaking
    /// Brief pause (e.g. 60ms CoreAudio settle after wake).
    case temporarilyPaused(reason: String)
    /// Error recovery in progress (e.g. 45s dictation-failure backoff).
    case recovering(reason: String)

    var displayName: String {
        switch self {
        case .unavailable(let r):       return "Unavailable: \(r)"
        case .idleListening:            return "Idle"
        case .wakeWordListening:        return "Wake-word armed"
        case .activelyListening:        return "Listening"
        case .processing:               return "Processing"
        case .speaking:                 return "Speaking"
        case .temporarilyPaused(let r): return "Paused: \(r)"
        case .recovering(let r):        return "Recovering: \(r)"
        }
    }
}

// MARK: - Lifecycle event log entry

struct ListeningLifecycleEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let fromState: String
    let toState: String
    let reason: String
    let caller: String

    var displayTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }
}

// MARK: - Stop reason (debug / diagnostics)

enum StopReason: String {
    case userCancelled   = "user_cancelled"
    case silenceTimeout  = "silence_timeout"
    case emptyFinal      = "empty_final"
    case recognizerError = "recognizer_error"
    case ttsInterrupt    = "tts_interrupt"
    case stateTransition = "state_transition"
    case unknown         = "unknown"
}

// MARK: - WebSocket wire format

struct WSCommand: Decodable {
    let id: String
    let source: String?
    let command: String
    let auth: String?
    let payload: WSPayload?
}

struct WSPayload: Decodable {
    let text: String?
    let name: String?
    let url: String?
    let context: String?
    let entity: String?
    let domain: String?
    let service: String?

    enum CodingKeys: String, CodingKey {
        case text, name, url, context, entity, domain, service
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text    = try c.decodeIfPresent(String.self, forKey: .text)
        name    = try c.decodeIfPresent(String.self, forKey: .name)
        url     = try c.decodeIfPresent(String.self, forKey: .url)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        entity  = try c.decodeIfPresent(String.self, forKey: .entity)
        domain  = try c.decodeIfPresent(String.self, forKey: .domain)
        service = try c.decodeIfPresent(String.self, forKey: .service)
    }
}

struct WSResponse: Encodable {
    let id: String
    let ok: Bool
    let message: String
    let data: [String: String]?

    init(id: String, ok: Bool, message: String, data: [String: String]? = nil) {
        self.id = id
        self.ok = ok
        self.message = message
        self.data = data
    }
}

// MARK: - Service errors

enum JarvisError: LocalizedError {
    case notConfigured(String)
    case permissionDenied(String)
    case deviceUnavailable(String)
    case invalidPayload(String)
    case unauthorized
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "Not configured: \(s)"
        case .permissionDenied(let s): return "Permission denied: \(s)"
        case .deviceUnavailable(let s): return "Device unavailable: \(s)"
        case .invalidPayload(let s): return "Invalid payload: \(s)"
        case .unauthorized: return "Unauthorized"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
