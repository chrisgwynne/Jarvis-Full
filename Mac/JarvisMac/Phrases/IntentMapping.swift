import Foundation

/// Maps stable command-definition IDs (e.g. `"show_news"`) to typed `Intent`
/// values so the phrase store can trigger concrete actions.
///
/// Parameterised intents (`openStoryAt`, `watchNewsChannel`, `rememberThis`,
/// etc.) return `nil` — they carry data that must come from the NLP parse
/// layer and therefore cannot be driven purely by phrase matching.
enum IntentMapping {

    // MARK: - Primary lookup

    static func intent(for commandId: String) -> Intent? {
        switch commandId {

        // News
        case "show_news":           return .showNews
        case "close_news":          return .hideNews
        case "watch_news":          return .watchNews
        case "summarise_news":      return .summariseNews
        case "next_news_channel":   return .nextNewsChannel
        case "prev_news_channel":   return .prevNewsChannel
        case "refresh_news":        return .refreshNews
        case "show_saved_news":     return .showSavedNews
        case "save_news_article":   return .saveNewsArticle
        case "stop_watching_news":  return .stopWatchingNews
        case "open_in_browser":     return .openInBrowser
        case "close_article":       return .hideArticle
        // open_story / summarise_story need an ordinal — handled by NLP
        case "open_story":          return nil
        case "summarise_story":     return nil

        // Camera / Vision
        case "show_camera":         return .showCameraOverlay
        case "close_camera":        return .hideCamera
        case "describe_camera":     return .whatCanYouSee
        case "take_photo":          return .takePhoto
        case "is_anyone_there":     return .isAnyoneThere
        case "describe_person":     return .describePerson
        case "what_is_on_desk":     return .whatIsOnDesk
        case "watch_desk":          return .watchTheDesk
        case "watch_room":          return .watchRoom
        case "stop_watching_camera": return .stopWatchingCamera
        case "look_at_this":        return .lookAtThis
        case "scan_this":           return .scanThis
        case "what_am_i_holding":   return .whatAmIHolding

        // UI modes
        case "focus_mode":          return .focusMode
        case "dashboard_mode":      return .dashboardMode
        case "mode_normal":         return .modeNormal
        case "mode_concise":        return .modeConcise
        case "mode_silent":         return .modeSilent
        case "mode_ambient":        return .modeAmbient

        // Overlays
        case "close_overlay":       return .closeOverlay
        case "maximise_overlay":    return .maximizeOverlay
        case "minimise_overlay":    return .minimizeOverlay
        case "pin_overlay":          return .pinOverlay
        case "unpin_overlay":        return .unpinOverlay
        case "overlay_reset_layout": return .overlayResetLayout
        case "overlay_focus_top":    return .overlayFocusTop
        case "show_diagnostics":    return .showTestOverlay
        case "show_chat":           return .showChat
        case "show_timeline":       return .showTimeline
        case "show_memory":         return .showMemoryOverlay
        case "show_screen":         return .showScreenOverlay
        case "show_reasoning":      return .showReasoning
        case "show_response_playbook": return .showResponsePlaybook
        case "show_personality":    return .showPersonalitySettings
        case "show_calendar_overlay": return .showCalendarOverlay
        case "show_tasks_overlay":  return .showTasksOverlay
        case "show_home_overlay":   return .showHomeOverlay
        case "show_github_overlay": return .showGitHubOverlay

        // HA Camera — show_ha_camera needs entity extraction via NLP, returns nil here;
        // close/all/mute/unmute/diagnostics are fully static.
        case "show_ha_camera":      return nil   // resolved by IntentRouter substring match
        case "close_ha_camera":     return .homeCloseCamera
        case "show_all_cameras":    return .homeShowAllCameras
        case "mute_ha_alerts":      return .homeMuteAlerts
        case "unmute_ha_alerts":    return .homeUnmuteAlerts
        case "show_ha_diagnostics": return .homeShowHADiagnostics

        // Time
        case "tell_time":           return .tellTime

        // Memory / Conversational Jarvis
        case "remember_last":       return .rememberLast
        case "log_progress_note":   return .saveToProjectMemory
        case "save_to_project_memory": return .saveToProjectMemory
        case "query_project_memory": return .queryProjectMemory(query: "")
        case "show_today_jarvis_log": return .showTodayJarvisLog
        case "pause_memory_logging": return .pauseMemoryLogging
        case "resume_memory_logging": return .resumeMemoryLogging
        case "do_not_save_this":    return .doNotSaveThis
        case "show_routing_diagnostics": return .showRoutingDiagnostics
        // Brain
        case "play_ping_pong":           return .playPingPong
        // Brain
        case "show_brain_overlay":       return .showBrainOverlay
        case "brain_summary_today":      return .brainSummaryToday
        case "brain_summary_week":       return .brainSummaryWeek
        // Sprint L — Surveillance / POI Vision
        case "show_surveillance_mode":  return .showSurveillanceMode
        case "hide_surveillance_mode":  return .hideSurveillanceMode
        case "start_surveillance":      return .startSurveillance
        case "stop_surveillance":       return .stopSurveillance
        case "describe_visual_scene":   return .describeVisualScene
        case "who_is_at_location":      return .whoIsAtLocation(location: "")
        case "any_people_detected":     return .anyPeopleDetected
        case "focus_camera":            return .focusCamera(name: "")
        case "last_motion_event":       return .lastMotionEvent
        case "show_threat_status":      return .showThreatStatus
        case "activate_threat_tracking": return .activateThreatTracking
        case "search_again":        return .searchAgain
        case "what_do_you_remember": return .whatDoYouRemember
        case "show_recent_memories": return .showRecentMemories
        case "what_was_i_doing":    return .whatWasIDoingEarlier
        case "show_recent_activity": return .showRecentActivity
        // remember_this / search_memory need payload — handled by NLP

        // Identity
        case "ask_my_name":         return .askMyName
        case "ask_assistant_name":  return .askAssistantName
        case "ask_personal_facts":  return .askPersonalFacts

        // Screen
        case "what_am_i_looking_at": return .whatAmILookingAt
        case "read_my_screen":      return .readMyScreen
        case "summarise_screen":    return .summariseScreen
        case "capture_screen":      return .captureScreen
        case "watch_screen":        return .watchThisScreen
        case "stop_watching_screen": return .stopWatchingScreen
        case "what_app_am_i_using": return .whatAppAmIUsing
        case "what_text_do_you_see": return .whatTextDoYouSee

        // Ambient Context
        case "what_am_i_working_on":        return .whatAmIWorkingOn
        case "what_failed_on_screen":       return .whatFailedOnScreen
        case "what_changed_on_screen":      return .whatChangedOnScreen
        case "watch_this":                  return .watchThis
        case "stop_watching":               return .stopWatching
        case "enable_ambient_context":      return .enableAmbientContext
        case "disable_ambient_context":     return .disableAmbientContext
        case "show_ambient_context_overlay": return .showAmbientContextOverlay
        case "show_runtime_diagnostics":     return .showRuntimeDiagnostics
        case "show_focus":                   return .showFocus
        case "explain_current_focus":        return .explainCurrentFocus
        case "show_spatial_interaction":     return .showSpatialInteraction
        case "hide_spatial_interaction":     return .hideSpatialInteraction

        // Spatial Interaction Phase 1 (Sprint M)
        case "save_workspace":      return .saveWorkspace(name: "")
        case "restore_workspace":   return .restoreWorkspace(name: "")
        case "list_workspaces":     return .listWorkspaces
        case "move_widget_left":    return .moveWidgetLeft
        case "move_widget_right":   return .moveWidgetRight
        case "move_widget_up":      return .moveWidgetUp
        case "move_widget_down":    return .moveWidgetDown
        case "resize_widget_large": return .resizeWidgetLarge
        case "resize_widget_small": return .resizeWidgetSmall
        case "minimize_widget":     return .minimizeWidget
        case "dock_widget":         return .dockWidget(edge: "left")
        case "snap_widget":         return .snapWidget(zone: "center")
        case "show_spatial_debug":  return .showSpatialDebug
        case "snap_window_left":    return .snapWindowLeft(appName: "")
        case "snap_window_right":   return .snapWindowRight(appName: "")
        case "tile_windows":        return .tileWindows
        case "focus_window":        return .focusWindow(appName: "")

        // Small Talk
        case "can_you_hear_me":     return .canYouHearMe
        case "are_you_listening":   return .areYouListening
        case "status":              return .status
        case "repeat_last":         return .repeatLast
        case "why_did_you_do_that": return .whyDidYouDoThat
        case "what_did_i_do_today": return .whatDidIDoToday
        case "show_attention_state": return .showAttentionState
        case "show_entity_graph":   return .showEntityGraph
        case "reload_personality":  return .reloadPersonality

        // Proactivity
        case "show_notifications":      return .showNotifications
        case "dismiss_notifications":   return .dismissNotifications
        case "pause_proactivity":       return .pauseProactivity
        case "resume_proactivity":      return .resumeProactivity
        case "mute_news_hour":          return .muteNewsForHour
        case "mute_news":               return .muteNews
        case "unmute_news":             return .unmuteNews
        case "open_that_story":         return .openThatStory
        case "summarise_that":          return .summariseThat
        case "show_latest_alert":       return .showLatestAlert
        case "dismiss_latest_alert":    return .dismissLatestAlert
        case "proactivity_useful":      return .proactivityUseful
        case "proactivity_not_useful":  return .proactivityNotUseful
        case "never_tell_me_this":      return .neverTellMeAboutThis
        case "always_tell_me_this":     return .alwaysTellMeAboutThis

        // Developer / workspace modes
        case "developer_mode":      return .developerMode
        case "workspace_mode":      return .workspaceMode
        case "tell_date":           return .tellDate

        // Listening lifecycle
        case "stop_listening":      return .disableListening
        case "start_listening":     return .enableListening
        case "stop_talking":        return .stopTalking

        // GitHub
        case "check_github":                return .checkGitHub
        case "github_dashboard":            return .githubDashboard
        case "github_list_prs":             return .githubListPRs(repo: nil)
        case "github_review_pr":            return .githubReviewPR(repo: nil, number: nil)
        case "github_stale_prs":            return .githubStalePRs(repo: nil)
        case "github_list_issues":          return .githubListIssues(repo: nil)
        case "github_stale_issues":         return .githubStaleIssues(repo: nil)
        case "github_create_issue":         return .githubCreateIssue(repo: nil, title: nil)
        case "github_recent_commits":       return .githubRecentCommits(repo: nil)
        case "github_changes_today":        return .githubChangesToday(repo: nil)
        case "github_check_ci":             return .githubCheckCI(repo: nil)
        case "github_list_repos":           return .githubListMyRepos
        case "github_active_repos":         return .githubActiveRepos
        case "github_neglected_repos":      return .githubNeglectedRepos
        case "github_create_repo":          return .githubCreateRepo(name: nil)
        case "github_describe_repo":        return .githubDescribeRepo(repo: nil)
        case "github_project_status":       return .githubProjectStatus(repo: nil)
        case "github_code_review":          return .githubCodeReview(repo: nil)
        case "github_summarise_diff":       return .githubSummariseDiff(repo: nil)

        // Timers / Stopwatch
        case "set_timer":           return nil   // parameterised: seconds + name from NLP
        case "cancel_timer":        return nil   // parameterised: name from NLP
        case "cancel_all_timers":   return .cancelAllTimers
        case "timer_status":        return .timerStatus
        case "start_stopwatch":     return .startStopwatch
        case "stop_stopwatch":      return .stopStopwatch
        case "stopwatch_status":    return .stopwatchStatus

        // Clipboard
        case "clipboard_read":      return .clipboardRead
        case "clipboard_copy":      return nil   // parameterised: text from NLP

        // Home Assistant
        case "home_status":         return .homeStatus
        case "home_run_automation": return nil   // parameterised: name from NLP
        case "home_turn_on":        return nil   // parameterised: entity from NLP
        case "home_turn_off":       return nil   // parameterised: entity from NLP
        case "home_set_brightness": return nil   // parameterised: entity + level from NLP
        case "home_set_color":      return nil   // parameterised: entity + color from NLP
        case "home_activate_scene": return nil   // parameterised: scene name from NLP
        case "home_open_cover":     return nil   // parameterised: entity from NLP
        case "home_close_cover":    return nil   // parameterised: entity from NLP
        case "check_lock":          return nil   // parameterised: entity resolved in IntentRouter
        case "home_lock":           return nil   // parameterised: entity from NLP
        case "home_unlock":         return nil   // parameterised: entity from NLP
        case "home_show_camera":    return nil   // parameterised: entity from NLP

        // Calendar / Weather / Briefing
        case "show_calendar":       return .showCalendar
        case "next_meeting":        return .nextMeeting
        case "meetings_today":      return .meetingsToday
        case "current_weather":     return .currentWeather
        case "weather_forecast":    return .weatherForecast(days: 1)  // default 1-day
        case "daily_briefing":      return .dailyBriefing
        case "jarvis_help":         return .jarvisHelp
        case "add_reminder":        return nil   // parameterised: text from NLP

        // Todoist
        case "show_tasks":          return .showTasks
        case "what_are_my_tasks":   return .whatAreMyTasks
        case "add_task":            return nil   // parameterised: text from NLP
        case "complete_task":       return nil   // parameterised: text from NLP
        case "overdue_tasks":       return .overdueTasks

        // Android / Mobile bridge
        case "show_android":            return .showAndroidOverlay
        case "android_status":          return .androidBridgeStatus
        case "phone_battery":           return .phoneBattery
        case "show_help":               return .showHelp
        case "ring_phone":              return .ringPhone
        case "phone_location":          return .phoneLocation
        case "read_notifications":      return .readNotifications
        case "call_contact":            return nil  // parameterised: name from NLP
        case "send_sms":                return nil  // parameterised: recipient + message from NLP
        case "whatsapp_voice_call":     return nil  // parameterised: contact name extracted by router
        case "whatsapp_video_call":     return nil  // parameterised: contact name extracted by router
        case "send_whatsapp":           return nil  // parameterised: recipient + message from NLP
        case "find_contact":            return nil  // parameterised: query from NLP
        case "start_navigation":        return nil  // parameterised: destination from NLP
        case "query_notification":      return nil  // parameterised: app from NLP
        case "capture_phone_camera":    return .capturePhoneCamera

        // Android phone event follow-ups
        case "call_back_last_caller":        return .callBackLastCaller
        case "reply_to_last_sender":         return .replyToLastSender(message: "")  // message extracted by router
        case "show_latest_android_message":  return .showLatestAndroidMessage

        // Phase-1 remote call control
        case "answer_call":                  return .answerCall
        case "decline_call":                 return .declineCall
        case "hang_up_call":                 return .hangUpCall
        case "speaker_on":                   return .speakerOn
        case "speaker_off":                  return .speakerOff

        // Obsidian
        case "show_obsidian":           return .showObsidianOverlay
        case "recent_obsidian_notes":   return .recentObsidianNotes
        case "search_obsidian":         return nil  // parameterised: query from NLP
        case "open_obsidian_note":      return nil  // parameterised: query from NLP
        case "read_obsidian_note":      return nil  // parameterised: query from NLP
        case "create_obsidian_note":    return nil  // parameterised: title + content from NLP
        case "append_obsidian_note":    return nil  // parameterised: title + text from NLP
        case "what_do_i_know_about":    return nil  // parameterised: topic from NLP

        // Apple Notes
        case "open_notes":    return .openNotes
        case "show_notes":    return .showNotes
        case "create_note":   return nil  // parameterised: title + body from NLP
        case "append_note":   return nil  // parameterised: title + body from NLP
        case "search_notes":  return nil  // parameterised: query from NLP

        // Email / Apple Mail
        case "check_email":        return .checkEmail
        case "unread_email":       return .unreadEmail
        case "read_latest_email":  return .readLatestEmail
        case "search_email":       return nil  // parameterised: query from NLP
        case "summarise_email":    return .summariseEmail
        case "draft_email":        return nil  // parameterised: to + subject + body
        case "reply_email":        return nil  // parameterised: to + body
        case "show_email":         return .showEmail
        case "important_email":    return .importantEmail

        // Shopify
        case "show_shopify":        return .showShopifyOverlay
        case "shopify_orders":      return .shopifyOrders
        case "shopify_revenue":     return .shopifyRevenue
        case "shopify_fulfilment":  return .shopifyFulfilment

        // Apps
        case "list_running_apps":   return .listRunningApps
        // System Settings — generic + pane-specific
        case "open_settings":                   return .openSystemSettings(pane: nil)
        case "open_settings_wifi":              return .openSystemSettings(pane: "wifi")
        case "open_settings_bluetooth":         return .openSystemSettings(pane: "bluetooth")
        case "open_settings_sound":             return .openSystemSettings(pane: "sound")
        case "open_settings_display":           return .openSystemSettings(pane: "display")
        case "open_settings_privacy":           return .openSystemSettings(pane: "privacy")
        case "open_settings_notifications":     return .openSystemSettings(pane: "notifications")
        case "open_settings_keyboard":          return .openSystemSettings(pane: "keyboard")
        case "open_settings_battery":           return .openSystemSettings(pane: "battery")
        case "open_settings_accessibility":     return .openSystemSettings(pane: "accessibility")
        // Volume
        case "volume_up":           return .volumeUp
        case "volume_down":         return .volumeDown
        case "mute":                return .mute
        case "unmute":              return .unmute
        case "get_volume":          return .getVolume
        // Files
        case "open_downloads":      return .openFolder(name: "downloads")
        case "open_desktop":        return .openFolder(name: "desktop")
        case "open_documents":      return .openFolder(name: "documents")
        case "open_latest_download": return .openLatestDownload
        // Windows
        case "show_desktop":        return .showDesktop
        case "lock_screen":         return .lockScreen
        case "sleep_display":       return .sleepDisplay
        // Connectivity toggles
        case "wifi_on":             return .wifiOn
        case "wifi_off":            return .wifiOff
        case "bluetooth_on":        return .bluetoothOn
        case "bluetooth_off":       return .bluetoothOff
        // Parameterised — need NLP extraction
        case "open_app":            return nil   // name extracted by IntentRouter
        case "activate_app":        return nil   // name extracted by IntentRouter
        case "quit_app":            return nil   // name extracted by IntentRouter
        case "hide_app":            return nil   // name extracted by IntentRouter
        case "find_file":           return nil   // query extracted by IntentRouter

        // Spotify
        case "spotify_play":        return .spotifyPlay(query: nil)   // bare "play music"
        case "spotify_pause":       return .spotifyPause
        case "spotify_next":        return .spotifyNext
        case "spotify_previous":    return .spotifyPrevious
        case "spotify_status":      return .spotifyWhatIsPlaying
        case "spotify_shuffle_on":  return .spotifyShuffle(on: true)
        case "spotify_shuffle_off": return .spotifyShuffle(on: false)

        // Reddit — parameterised commands return nil; the IntentRouter
        // extracts the subreddit name / search query and re-routes via
        // `route(_:)` so the right associated value gets attached.
        case "reddit_show":               return .showReddit
        case "reddit_show_top":           return .showRedditTop
        case "reddit_show_subreddit":     return nil  // name extracted by router
        case "reddit_query":              return nil  // query extracted by router
        case "reddit_summarise_post":     return .redditSummarisePost
        case "reddit_summarise_comments": return .redditSummariseComments
        case "reddit_open_first":         return .redditOpenIndex(index: 0)
        case "reddit_open_in_browser":    return .redditOpenInBrowser
        case "reddit_show_comments":      return .redditShowComments
        case "reddit_save_post":          return .redditSavePost
        case "reddit_refresh":            return .redditRefresh

        default:                    return nil
        }
    }

    // MARK: - Reverse lookup (intent → commandId, for voice learning)

    /// Returns the commandId that best describes a given intent, or nil
    /// for parameterised intents that cannot be reverse-mapped cleanly.
    static func commandId(for intent: Intent) -> String? {
        switch intent {
        case .showNews:             return "show_news"
        case .hideNews:             return "close_news"
        case .watchNews:            return "watch_news"
        case .summariseNews:        return "summarise_news"
        case .nextNewsChannel:      return "next_news_channel"
        case .prevNewsChannel:      return "prev_news_channel"
        case .showCameraOverlay:    return "show_camera"
        case .hideCamera:           return "close_camera"
        case .whatCanYouSee:        return "describe_camera"
        case .whatAmIHolding:       return "what_am_i_holding"
        case .focusMode:            return "focus_mode"
        case .dashboardMode:        return "dashboard_mode"
        case .closeOverlay:          return "close_overlay"
        case .maximizeOverlay:       return "maximise_overlay"
        case .minimizeOverlay:       return "minimise_overlay"
        case .overlayResetLayout:    return "overlay_reset_layout"
        case .overlayFocusTop:       return "overlay_focus_top"
        case .showTestOverlay:      return "show_diagnostics"
        case .showChat:             return "show_chat"
        case .showTimeline:         return "show_timeline"
        case .showMemoryOverlay:    return "show_memory"
        case .tellTime:             return "tell_time"
        case .rememberLast:         return "remember_last"
        case .disableListening:     return "stop_listening"
        case .enableListening:      return "start_listening"
        case .canYouHearMe:         return "can_you_hear_me"
        case .areYouListening:      return "are_you_listening"
        case .repeatLast:           return "repeat_last"
        case .stopTalking:          return "stop_talking"
        case .whatAmILookingAt:     return "what_am_i_looking_at"
        case .readMyScreen:         return "read_my_screen"
        case .modeNormal:           return "mode_normal"
        case .modeConcise:          return "mode_concise"
        case .modeSilent:           return "mode_silent"
        case .modeAmbient:          return "mode_ambient"
        case .showSpatialInteraction: return "show_spatial_interaction"
        case .hideSpatialInteraction: return "hide_spatial_interaction"
        default:                    return nil
        }
    }
}
