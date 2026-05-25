import Foundation

// MARK: - Response style

enum ResponseStyle: String, Codable, CaseIterable, Identifiable {
    case consistent // always use first/default phrase
    case varied     // rotate randomly among phrases
    case minimal    // shortest phrase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .consistent: return "Consistent"
        case .varied:     return "Varied"
        case .minimal:    return "Minimal"
        }
    }

    var description: String {
        switch self {
        case .consistent: return "Always uses the first (default) phrase."
        case .varied:     return "Randomly picks from available variants."
        case .minimal:    return "Chooses the shortest available phrase."
        }
    }
}

// MARK: - Response keys

enum ResponseKey {
    // App / URL
    static let openAppSuccess          = "open_app.success"
    static let openAppFailure          = "open_app.failure"
    static let openAppOnPhoneSuccess   = "open_app_on_phone.success"
    static let openAppOnPhoneFailure   = "open_app_on_phone.failure"
    static let openURLSuccess          = "open_url.success"

    // Device
    static let micUpdated         = "device.mic_updated"
    static let cameraUpdated      = "device.camera_updated"

    // Camera
    static let cameraOCREmpty     = "camera.ocr.empty"
    static let cameraOCRFound     = "camera.ocr.found"
    static let cameraWatchStopped = "camera.watch.stopped"
    static let cameraWatchAlready = "camera.watch.already"
    static let cameraWatchRoom    = "camera.watch.room"
    static let cameraNotReady     = "camera.not_ready"
    static let cameraPresenceFound = "camera.presence.found"
    static let cameraPresenceNone  = "camera.presence.none"
    static let cameraLooking      = "camera.looking"        // toast while analysing
    static let cameraHeldObject   = "camera.held_object"    // result of detectHeldObject
    static let cameraHeldChecking = "camera.held_checking"  // acknowledgement while processing

    // Screen
    static let screenTextEmpty    = "screen.text.empty"
    static let screenTextFound    = "screen.text.found"
    static let screenAppName      = "screen.app_name"
    static let screenWatchStarted = "screen.watch.started"
    static let screenWatchStopped = "screen.watch.stopped"
    static let screenCaptureFailed = "screen.capture.failed"

    // Ambient context
    static let ambientWorkingOn       = "ambient.working_on"
    static let ambientWorkingOnUnknown = "ambient.working_on.unknown"
    static let ambientErrors          = "ambient.errors"
    static let ambientNoErrors        = "ambient.no_errors"
    static let ambientChanged         = "ambient.changed"
    static let ambientNoChange        = "ambient.no_change"
    static let ambientWatchStarted    = "ambient.watch.started"
    static let ambientWatchStopped    = "ambient.watch.stopped"
    static let ambientEnabled         = "ambient.enabled"
    static let ambientDisabled        = "ambient.disabled"

    // Memory
    static let memorySaved        = "memory.saved"
    static let memorySavedLast    = "memory.saved_last"
    static let memoryNothingToSave = "memory.nothing_to_save"
    static let memorySearchEmpty  = "memory.search.empty"
    static let memorySearchFound  = "memory.search.found"
    static let memorySearchNoPrev = "memory.search.no_previous"
    static let memoryUnavailable  = "memory.unavailable"
    static let memoryNone         = "memory.none"
    static let memoryRecentEmpty  = "memory.recent.empty"
    static let memoryRecentFound  = "memory.recent.found"
    static let memoryOverlayOpened = "memory.overlay.opened"

    // Activity
    static let activityUnavailable = "activity.unavailable"
    static let activityRecent     = "activity.recent"

    // Home Assistant
    static let homeTurnOnSuccess       = "home.turn_on.success"
    static let homeTurnOnFailure       = "home.turn_on.failure"
    static let homeTurnOffSuccess      = "home.turn_off.success"
    static let homeTurnOffFailure      = "home.turn_off.failure"
    static let homeEntityState         = "home.entity_state"
    static let homeEntityUnknown       = "home.entity_unknown"
    static let homeBrightnessSuccess   = "home.brightness.success"
    static let homeBrightnessFailure   = "home.brightness.failure"
    static let homeColorSuccess        = "home.color.success"
    static let homeColorFailure        = "home.color.failure"
    static let homeSceneSuccess        = "home.scene.success"
    static let homeSceneFailure        = "home.scene.failure"
    static let homeCoverOpenSuccess    = "home.cover.open.success"
    static let homeCoverCloseSuccess   = "home.cover.close.success"
    static let homeCoverFailure        = "home.cover.failure"
    static let homeLockSuccess         = "home.lock.success"
    static let homeLockFailure         = "home.lock.failure"
    static let homeUnlockSuccess       = "home.unlock.success"
    static let homeUnlockFailure       = "home.unlock.failure"
    static let homeCameraOpened        = "home.camera.opened"
    static let homeCameraUnavailable   = "home.camera.unavailable"
    static let homeNotConfigured       = "home.not_configured"
    static let homeAutomationTriggered = "home.automation_triggered"
    static let homeAutomationNotFound  = "home.automation_not_found"
    static let homeOverlayOpened       = "home.overlay_opened"

    // HA Camera overlay (new deep-integration paths)
    static let haCameraShowing         = "ha.camera.showing"
    static let haCameraUnavailable     = "ha.camera.unavailable"
    static let haCameraNotFound        = "ha.camera.not_found"
    static let haCameraClosed          = "ha.camera.closed"
    static let haAllCamerasOpened      = "ha.all_cameras.opened"
    static let haMotionDoor            = "ha.motion.door"
    static let haMotionGeneric         = "ha.motion.generic"
    static let haConnectionFailed      = "ha.connection.failed"
    static let haAlertsMuted           = "ha.alerts.muted"
    static let haAlertsUnmuted         = "ha.alerts.unmuted"
    static let haDiagnosticsOpened     = "ha.diagnostics.opened"

    // Calendar
    static let calendarNoEvents        = "calendar.no_events"
    static let calendarToday           = "calendar.today"
    static let calendarNextMeeting     = "calendar.next_meeting"
    static let calendarNoUpcoming      = "calendar.no_upcoming"
    static let calendarReminderAdded   = "calendar.reminder_added"
    static let calendarReminderFailed  = "calendar.reminder_failed"
    static let calendarNotConfigured   = "calendar.not_configured"
    static let calendarOverlayOpened   = "calendar.overlay_opened"

    // Todoist
    static let todoistNoTasks          = "todoist.no_tasks"
    static let todoistTasks            = "todoist.tasks"
    static let todoistTaskAdded        = "todoist.task_added"
    static let todoistTaskAddFailed    = "todoist.task_add_failed"
    static let todoistTaskCompleted    = "todoist.task_completed"
    static let todoistTaskCompleteFailed = "todoist.task_complete_failed"
    static let todoistNotConfigured    = "todoist.not_configured"
    static let todoistOverdueNone      = "todoist.overdue_none"
    static let todoistOverdue          = "todoist.overdue"
    static let tasksOverlayOpened      = "todoist.overlay_opened"

    // Android
    static let androidContinue    = "android.continue"
    static let androidNothing     = "android.nothing"

    // UI
    static let showContext        = "ui.show_context"
    static let repeatEmpty        = "ui.repeat.empty"
    static let orbMode            = "ui.orb_mode"
    static let dashboardMode      = "ui.dashboard_mode"
    static let overlayTestOpened  = "overlay.test.opened"
    static let overlayPinned      = "overlay.pinned"
    static let overlayUnpinned    = "overlay.unpinned"
    static let overlayLayoutReset = "overlay.layout.reset"
    static let overlayBroughtToFront = "overlay.brought_to_front"
    static let spatialInteractionOpen  = "spatial.opened"
    static let spatialInteractionClose = "spatial.closed"
    static let debugHUDOn         = "debug.hud.on"
    static let debugHUDOff        = "debug.hud.off"

    // Operating modes
    static let modeNormal         = "mode.normal"
    static let modeConcise        = "mode.concise"
    static let modeAmbient        = "mode.ambient"

    // Timeline
    static let timelineOpened     = "timeline.opened"
    static let whatDidIDoToday    = "timeline.today"

    // Reasoning
    static let reasoningOpened    = "reasoning.opened"

    // News
    static let newsOpened          = "news.opened"
    static let newsAlreadyOpen     = "news.already_open"
    static let newsRefreshed       = "news.refreshed"
    static let newsNoArticles      = "news.no_articles"
    static let newsSaved           = "news.saved"
    static let newsNoRecentArticle = "news.no_recent_article"
    static let newsWatchStarted    = "news.watch.started"
    static let newsWatchStopped    = "news.watch.stopped"
    static let newsWatching        = "news.watching"
    static let newsChannelNone     = "news.channel_none"
    static let newsChannelSwitched = "news.channel_switched"
    static let newsChannelNotFound = "news.channel_not_found"
    static let newsChannelsNone    = "news.channels_none"
    static let newsSearchEmpty     = "news.search.empty"
    static let newsSearchFound     = "news.search.found"
    static let newsArticleLimited  = "news.article_limited"
    static let newsArticleOpening  = "news.article_opening"
    static let newsArticleBrowser  = "news.article_browser"
    static let newsArticleNoFocus  = "news.article_no_focus"
    static let newsArticleClosed   = "news.article_closed"
    static let newsArticleNone     = "news.article_none"
    static let newsSavedOpened     = "news.saved_opened"
    static let newsFeedNotFound    = "news.feed_not_found"
    static let newsClosed          = "news.closed"
    static let newsAlreadyClosed   = "news.already_closed"

    // UI / overlay
    static let overlayClosed       = "ui.overlay.closed"
    static let overlayNoneOpen     = "ui.overlay.none_open"
    static let cameraOverlayOpen   = "ui.camera.opened"
    static let cameraOverlayAlready = "ui.camera.already_open"
    static let cameraOverlayClosed  = "ui.camera.closed"
    static let cameraOverlayAlreadyClosed = "ui.camera.already_closed"

    // Status / identity
    static let listeningConfirm    = "ui.listening_confirm"
    static let hearingConfirm      = "ui.hearing_confirm"
    static let timeNow             = "ui.time.current"
    static let dateToday           = "ui.date.current"
    static let dictationNeeded     = "ui.dictation_needed"

    // Attention / mode debug
    static let attentionState      = "ui.attention_state"

    // Home entities debug
    static let homeEntitiesNone    = "home.entities.none"
    static let homeEntitiesList    = "home.entities.list"

    // System control — app management
    static let appOpened          = "system.app.opened"
    static let appNotFound        = "system.app.not_found"
    static let appClarify         = "system.app.clarify"
    static let appQuit            = "system.app.quit"
    static let appHidden          = "system.app.hidden"
    static let appActivated       = "system.app.activated"
    static let appsRunning        = "system.apps.running"

    // System control — settings
    static let settingsOpened     = "system.settings.opened"
    static let settingsPaneOpened = "system.settings.pane_opened"

    // System control — volume
    static let volumeSet          = "system.volume.set"
    static let volumeUp           = "system.volume.up"
    static let volumeDown         = "system.volume.down"
    static let volumeMuted        = "system.volume.muted"
    static let volumeUnmuted      = "system.volume.unmuted"
    static let volumeCurrent      = "system.volume.current"

    // System control — files
    static let folderOpened       = "system.folder.opened"
    static let folderNotFound     = "system.folder.not_found"
    static let fileSearchResults  = "system.file.search_results"
    static let fileSearchEmpty    = "system.file.search_empty"
    static let latestDownload     = "system.file.latest_download"
    static let latestDownloadNone = "system.file.latest_download_none"

    // System control — windows / desktop
    static let desktopShown       = "system.desktop.shown"
    static let screenLocked       = "system.screen.locked"
    static let displaySlept       = "system.display.slept"
    static let accessibilityNeeded = "system.permission.accessibility"

    // System control — connectivity toggles
    static let wifiEnabled        = "system.wifi_enabled"
    static let wifiDisabled       = "system.wifi_disabled"
    static let bluetoothEnabled   = "system.bluetooth_enabled"
    static let bluetoothDisabled  = "system.bluetooth_disabled"

    // Proactivity / notifications
    static let notificationsNone   = "notifications.none"
    static let notificationsPending = "notifications.pending"
    static let notificationsCleared = "notifications.cleared"
    static let proactivityPaused   = "proactivity.paused"
    static let proactivityResumed  = "proactivity.resumed"
    static let newsNotifsMutedHour = "news.notifs.muted_hour"
    static let newsNotifsMuted     = "news.notifs.muted"
    static let newsNotifsUnmuted   = "news.notifs.unmuted"

    // Proactivity open / dismiss feedback
    static let proactivityOpening  = "proactivity.opening"
    static let proactivityStoryNotFound = "proactivity.story_not_found"
    static let proactivityNothingRecent = "proactivity.nothing_recent"
    static let proactivityNothingFlagged = "proactivity.nothing_flagged"
    static let proactivityDismissed = "proactivity.dismissed"
    static let proactivityNothingToDismiss = "proactivity.nothing_to_dismiss"
    static let proactivityNoSummary = "proactivity.no_summary"
    static let proactivitySummary  = "proactivity.summary"
    static let proactivityConfused = "proactivity.confused"
    static let proactivityPosFeedback = "proactivity.positive_feedback"
    static let proactivityNegFeedback = "proactivity.negative_feedback"
    static let proactivityPrefSet  = "proactivity.pref_set"
    static let proactivityPrefGeneric = "proactivity.pref_generic"
    static let proactivityPrefPriority = "proactivity.pref_priority"
    static let proactivityPrefPriorityGeneric = "proactivity.pref_priority_generic"

    // App / system misc
    static let appIdentifyFailed   = "system.app.identify_failed"
    static let appPermissionRequired = "system.app.permission_required"
    static let settingsOpenFailed  = "system.settings.open_failed"
    static let volumeReadFailed    = "system.volume.read_failed"
    static let finderRevealed      = "system.finder.revealed"
    static let appsNoneRunning     = "system.apps.none_running"
    static let summariseUnavailable = "news.summarise_unavailable"
    static let newsArticleNoLink   = "news.article_no_link"

    // GitHub
    static let githubSummary         = "github.summary"
    static let githubNone            = "github.none"
    static let githubOverlayOpened   = "github.overlay_opened"
    static let githubNotConfigured   = "github.not_configured"

    // GitHub Intelligence
    static let githubDashboardOpened = "github.dashboard_opened"
    static let githubPRsSummary      = "github.prs_summary"
    static let githubIssuesSummary   = "github.issues_summary"
    static let githubCISummary       = "github.ci_summary"
    static let githubCommitsSummary  = "github.commits_summary"
    static let githubRepoSummary     = "github.repo_summary"
    static let githubRepoCreated     = "github.repo_created"
    static let githubRepoCreating    = "github.repo_creating"
    static let githubNeglected       = "github.neglected"
    static let githubProjectStatus   = "github.project_status"
    static let githubCodeReviewDone  = "github.code_review_done"
    static let githubIssueCreated    = "github.issue_created"
    static let githubConfirmAction   = "github.confirm_action"
    static let githubActionRejected  = "github.action_rejected"
    static let githubError           = "github.error"
    static let githubWizardNextQ     = "github.wizard_next_q"
    static let githubNoPRs           = "github.no_prs"
    static let githubPRCreatePrompt  = "github.pr_create_prompt"
    static let githubNoStalePRs      = "github.no_stale_prs"
    static let githubStalePRs        = "github.stale_prs"
    static let githubIssueCreateFail = "github.issue_create_failed"
    static let githubIssueTitleAsk   = "github.issue_title_ask"
    static let githubNoCommits       = "github.no_commits"
    static let githubCommits         = "github.commits"
    static let githubNoRepos         = "github.no_repos"
    static let githubTopRepos        = "github.top_repos"
    static let githubMostActive      = "github.most_active"
    static let githubNoPRsToReview   = "github.no_prs_to_review"

    // LLM errors
    static let llmTimeout          = "llm.timeout"
    static let llmUnavailable      = "llm.unavailable"
    static let llmBlocked          = "llm.blocked"
    static let llmNoProblem        = "llm.no_problem"

    // MARK: - LLM Fallback Responses
    static let llmUnknownFallback      = "llm.unknown_fallback"
    static let llmUnavailableFallback  = "llm.unavailable_fallback"
    static let llmTimeoutFallback      = "llm.timeout_fallback"
    static let llmMalformedFallback    = "llm.malformed_fallback"

    // Camera desk watch
    static let cameraWatchDeskStarted = "camera.watch.desk_started"

    // Android context
    static let androidFromPhone    = "android.from_phone"

    // Teach / learn phrase
    static let teachSuccess        = "teach.success"
    static let teachFailed         = "teach.failed"
    static let teachCommandAdded   = "teach.command_added"
    static let teachCommandFailed  = "teach.command_failed"
    static let teachCommandUnknown = "teach.command_unknown"

    // Developer / workspace
    static let developerModeOn     = "ui.developer_mode"
    static let workspaceMode       = "ui.workspace_mode"

    // Listening lifecycle
    static let listeningEnabled    = "ui.listening_enabled"
    static let listeningDisabled   = "ui.listening_disabled"

    // Weather
    static let weatherCurrent          = "weather.current"
    static let weatherForecast         = "weather.forecast"
    static let weatherRain             = "weather.rain"
    static let weatherNotReady         = "weather.not_ready"
    static let weatherLocationDenied   = "weather.location_denied"

    // Shopify
    static let shopifyOrders     = "shopify.orders"
    static let shopifyNoOrders   = "shopify.no_orders"
    static let shopifyRevenue    = "shopify.revenue"
    static let shopifyFulfilment = "shopify.fulfilment"
    static let shopifyOverlay    = "shopify.overlay"
    static let shopifyNotConfig  = "shopify.not_configured"

    // Obsidian
    static let obsidianOverlay        = "obsidian.overlay"
    static let obsidianNotConfigured  = "obsidian.not_configured"
    static let obsidianSearchResult   = "obsidian.search_result"
    static let obsidianNoResults      = "obsidian.no_results"
    static let obsidianNoteRead       = "obsidian.note_read"
    static let obsidianNoteCreated    = "obsidian.note_created"
    static let obsidianNoteAppended   = "obsidian.note_appended"
    static let obsidianNoteNotFound   = "obsidian.note_not_found"
    static let obsidianRecentNotes    = "obsidian.recent_notes"
    static let obsidianIndexing       = "obsidian.indexing"

    // Apple Notes
    static let notesOpened           = "notes.opened"
    static let notesCreated          = "notes.created"
    static let notesAppended         = "notes.appended"
    static let notesNotFound         = "notes.not_found"
    static let notesSearchResult     = "notes.search_result"
    static let notesNoResults        = "notes.no_results"
    static let notesPermissionError  = "notes.permission_error"
    static let notesNeedTitle        = "notes.need_title"
    static let notesNeedBody         = "notes.need_body"
    static let notesNeedQuery        = "notes.need_query"

    // Email / Apple Mail
    static let emailOpened           = "email.opened"
    static let emailUnreadSummary    = "email.unread_summary"
    static let emailNoneFound        = "email.none_found"
    static let emailDraftCreated     = "email.draft_created"
    static let emailSearchSummary    = "email.search_summary"
    static let emailImportantSummary = "email.important_summary"
    static let emailPermissionNeeded = "email.permission_needed"
    static let emailNeedRecipient    = "email.need_recipient"
    static let emailNeedSubject      = "email.need_subject"
    static let emailNeedBody         = "email.need_body"
    static let emailNeedQuery        = "email.need_query"

    // Help / briefing
    static let jarvisHelp              = "ui.help"
    static let dailyBriefing           = "ui.daily_briefing"
    static let dailyBriefingEmpty      = "ui.daily_briefing_empty"

    // Timers
    static let timerSet           = "timer.set"
    static let timerExpired       = "timer.expired"
    static let timerCancelled     = "timer.cancelled"
    static let timerStatus        = "timer.status"
    static let timerNone          = "timer.none"

    // Stopwatch
    static let stopwatchStarted   = "stopwatch.started"
    static let stopwatchStopped   = "stopwatch.stopped"
    static let stopwatchStatus    = "stopwatch.status"

    // Clipboard
    static let clipboardContent   = "clipboard.content"
    static let clipboardEmpty     = "clipboard.empty"
    static let clipboardCopied    = "clipboard.copied"

    // Spotify
    static let spotifyPlaying     = "spotify.playing"
    static let spotifyPaused      = "spotify.paused"
    static let spotifyResumed     = "spotify.resumed"
    static let spotifySkipped     = "spotify.skipped"
    static let spotifyBack        = "spotify.back"
    static let spotifyNowPlaying  = "spotify.now_playing"
    static let spotifyNotPlaying  = "spotify.not_playing"
    static let spotifyNotConfig   = "spotify.not_configured"
    static let spotifyError       = "spotify.error"
    static let spotifyShuffleOn   = "spotify.shuffle_on"
    static let spotifyShuffleOff  = "spotify.shuffle_off"
    static let spotifyVolume      = "spotify.volume"

    // MARK: - Android Bridge
    static let androidCalling            = "android.calling"
    static let androidMessageSent        = "android.message_sent"
    static let androidPhoneOffline       = "android.phone_offline"
    static let androidPermissionRequired = "android.permission_required"
    static let androidContactAmbiguous   = "android.contact_ambiguous"
    static let androidCommandFailed      = "android.command_failed"
    static let androidNavigating         = "android.navigating"
    static let androidRinging            = "android.ringing"
    static let androidNotificationsRead  = "android.notifications_read"
    static let androidContactFound       = "android.contact_found"
    static let androidStatus             = "android.status"
    /// Spoken when we try a command and the phone reports it needs a permission
    /// that hasn't been granted in the Android app yet.
    static let androidNeedsPermission    = "android.needs_permission"
    /// Phone battery answers — rendered from the latest heartbeat cache.
    /// Three variants because the user-facing sentence shape depends on
    /// whether the phone is charging, on battery, or completely offline.
    static let phoneBatteryCharging      = "android.battery.charging"
    static let phoneBatteryDischarging   = "android.battery.discharging"
    static let phoneBatteryUnknown       = "android.battery.unknown"
    static let phoneBatteryOffline       = "android.battery.offline"

    // Android phone events
    static let androidIncomingCall        = "android.event.incoming_call"
    static let androidMissedCall          = "android.event.missed_call"
    static let androidSMSReceived         = "android.event.sms_received"
    static let androidWhatsAppReceived    = "android.event.whatsapp_received"
    static let androidNotification        = "android.event.notification"
    static let androidCallEnded           = "android.event.call_ended"
    static let androidBatteryLow          = "android.event.battery_low"
    static let androidPermissionEvent     = "android.event.permission_required"
    static let androidNoCallerContext     = "android.no_caller_context"
    static let androidNoSenderContext     = "android.no_sender_context"
    static let androidCallBackConfirm     = "android.call_back_confirm"

    // Phase-1 call control
    static let androidAnswerCall          = "android.answer_call"
    static let androidDeclineCall         = "android.decline_call"
    static let androidHangUp              = "android.hang_up"
    static let androidSpeakerOn           = "android.speaker_on"
    static let androidSpeakerOff          = "android.speaker_off"
    static let androidNoActiveCall        = "android.no_active_call"

    // WhatsApp calls
    static let whatsAppVoiceCallStarting  = "android.whatsapp.voice_starting"
    static let whatsAppVideoCallStarting  = "android.whatsapp.video_starting"
    static let whatsAppContactNotFound    = "android.whatsapp.contact_not_found"
    static let whatsAppNotInstalled       = "android.whatsapp.not_installed"

    // Conversational Jarvis (Sprint K)
    static let progressSaved        = "conv.progress_saved"
    // memorySaved already defined above as "memory.saved" — reuse that key
    static let memoryLoggingPaused  = "conv.logging_paused"
    static let memoryLoggingResumed = "conv.logging_resumed"
    static let doNotSaveThis        = "conv.do_not_save"
    static let noProjectMemory      = "conv.no_project_memory"
    static let showingProjectStatus = "conv.showing_project_status"
    static let todayLogNotFound     = "conv.today_log_not_found"

    // Visual Intelligence / POI Surveillance (Sprint L)
    static let surveillanceActive      = "vision.surveillance_active"
    static let surveillanceStopped     = "vision.surveillance_stopped"
    static let sceneDescription        = "vision.scene_description"
    static let noActivityDetected      = "vision.no_activity"
    static let threatStatusReport      = "vision.threat_status"
    static let motionEventReport       = "vision.motion_event"
    static let personDetectedAlert     = "vision.person_detected"
    static let threatEscalated         = "vision.threat_escalated"
    static let cameraFocused           = "vision.camera_focused"
    static let surveillanceModeOpened  = "vision.overlay_opened"
    static let trackingActivated       = "vision.tracking_activated"

    // Spatial Interaction Phase 1 (Sprint M)
    static let workspaceSaved       = "spatial.workspace_saved"
    static let workspaceRestored    = "spatial.workspace_restored"
    static let workspaceNotFound    = "spatial.workspace_not_found"
    static let workspaceList        = "spatial.workspace_list"
    static let noWorkspacesSaved    = "spatial.no_workspaces"
    static let widgetMoved          = "spatial.widget_moved"
    static let widgetResized        = "spatial.widget_resized"
    static let widgetMinimized      = "spatial.widget_minimized"
    static let widgetDocked         = "spatial.widget_docked"
    static let widgetSnapped        = "spatial.widget_snapped"
    static let noWidgetHovered      = "spatial.no_widget_hovered"
    static let windowSnapped        = "spatial.window_snapped"
    static let windowNotFound       = "spatial.window_not_found"
    static let windowsTiled         = "spatial.windows_tiled"
    static let windowFocused        = "spatial.window_focused"

    // Speech Latency Diagnostics
    static let showSpeechLatency = "diag.show_speech_latency"

    // Focus Awareness (Sprint W)
    static let showFocus      = "context.show_focus"
    static let explainFocus   = "context.explain_focus"
    static let focusUnknown   = "context.focus_unknown"

    // Brain
    static let brainOverlayOpened  = "brain.overlay_opened"
    static let brainSummaryToday   = "brain.summary_today"
    static let brainSummaryWeek    = "brain.summary_week"

    // Local Learning
    static let learningAcknowledge    = "learning.acknowledge"
    static let learningShowTraining   = "learning.show_training"

    // Games
    static let playPingPong        = "game.ping_pong"

    // Unknown
    static let unknownIntent      = "unknown_intent"
}
