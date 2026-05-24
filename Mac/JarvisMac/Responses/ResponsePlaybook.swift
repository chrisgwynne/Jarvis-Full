import Foundation

/// Built-in default phrases for every response key. First phrase = default/consistent.
/// Shortest phrase = minimal candidate. All are user-overridable via ResponseTemplateStore.
enum ResponsePlaybook {

    static let defaults: [String: [String]] = [

        // MARK: App / URL
        ResponseKey.openAppSuccess: [
            "Opening {app}.",
            "Launching {app} now.",
            "Right away."
        ],
        ResponseKey.openAppFailure: [
            "Couldn't open {app}.",
            "I wasn't able to open {app}.",
            "Failed to open {app}."
        ],
        ResponseKey.openAppOnPhoneSuccess: [
            "Opening {app} on your phone.",
            "Launching {app} on your phone now.",
            "On it — opening {app} on your phone."
        ],
        ResponseKey.openAppOnPhoneFailure: [
            "Couldn't open {app} on your phone.",
            "Your phone didn't respond — is it connected?",
            "Failed to open {app} on your phone."
        ],
        ResponseKey.openURLSuccess: [
            "Opening link.",
            "Opening it now.",
            "On it."
        ],

        // MARK: Device
        ResponseKey.micUpdated: [
            "Microphone updated.",
            "Switched microphone.",
            "Done."
        ],
        ResponseKey.cameraUpdated: [
            "Camera updated.",
            "Switched camera.",
            "Done."
        ],

        // MARK: Camera
        ResponseKey.cameraOCREmpty: [
            "I don't see any readable text right now.",
            "No text visible.",
            "Nothing to read."
        ],
        ResponseKey.cameraOCRFound: [
            "I can read: {text}.",
            "The text says: {text}.",
            "{text}."
        ],
        ResponseKey.cameraWatchStopped: [
            "Stopped watching.",
            "Camera watch off.",
            "Done."
        ],
        ResponseKey.cameraWatchAlready: [
            "I'm already watching.",
            "Already on it.",
            "Watching."
        ],
        ResponseKey.cameraWatchRoom: [
            "Watching the room.",
            "Keeping an eye on the room.",
            "On it."
        ],
        ResponseKey.cameraNotReady: [
            "Camera isn't ready.",
            "The camera isn't available right now.",
            "No camera."
        ],
        ResponseKey.cameraPresenceFound: [
            "Yes, I can see {count} {count_label}. {summary}",
            "I see {count} {count_label}.",
            "{count} {count_label} visible."
        ],
        ResponseKey.cameraPresenceNone: [
            "I don't see anyone.",
            "No one visible.",
            "All clear."
        ],
        ResponseKey.cameraLooking: [
            "Looking now…",
            "Let me check…",
            "One moment…",
        ],

        ResponseKey.cameraHeldChecking: [
            "Let me see what you're holding…",
            "Looking at your hands…",
            "Checking what's in your hands…",
        ],

        ResponseKey.cameraHeldObject: [
            "{description}",
        ],

        // MARK: Screen
        ResponseKey.screenTextEmpty: [
            "I don't see any readable text on screen right now.",
            "No text on screen.",
            "Nothing readable."
        ],
        ResponseKey.screenTextFound: [
            "I can see: {text}.",
            "On screen: {text}.",
            "{text}."
        ],
        ResponseKey.screenAppName: [
            "You're using {app}.",
            "That's {app}.",
            "{app}."
        ],
        ResponseKey.screenWatchStarted: [
            "I'll keep an eye on your screen and update when things change.",
            "Screen watch on.",
            "Watching your screen."
        ],
        ResponseKey.screenWatchStopped: [
            "Screen watching stopped.",
            "Screen watch off.",
            "Done."
        ],
        ResponseKey.screenCaptureFailed: [
            "I couldn't capture the screen. Check Screen Recording permission in System Settings.",
            "Screen capture failed. Check permissions.",
            "Permission required."
        ],

        // MARK: Ambient Context
        ResponseKey.ambientWorkingOn: [
            "{task}",
            "You're currently {task}.",
            "Looks like {task}."
        ],
        ResponseKey.ambientWorkingOnUnknown: [
            "I'm not sure what you're working on right now.",
            "I don't have context on your current task.",
            "Background awareness isn't capturing anything yet."
        ],
        ResponseKey.ambientErrors: [
            "I can see {errors}.",
            "There's an error: {errors}.",
            "Looks like something failed — {errors}."
        ],
        ResponseKey.ambientNoErrors: [
            "I don't see any errors on screen.",
            "Looks clean — no errors visible.",
            "Nothing failed that I can see."
        ],
        ResponseKey.ambientChanged: [
            "Since last time: {change}.",
            "Something changed — {change}."
        ],
        ResponseKey.ambientNoChange: [
            "Nothing significant has changed.",
            "Looks about the same as before.",
            "No notable changes since the last check."
        ],
        ResponseKey.ambientWatchStarted: [
            "Watching {app}. I'll alert you to anything important.",
            "Watch mode on for {app}.",
            "I'm keeping an eye on {app}."
        ],
        ResponseKey.ambientWatchStopped: [
            "Watch mode off.",
            "Stopped monitoring.",
            "Done watching."
        ],
        ResponseKey.ambientEnabled: [
            "Background awareness enabled.",
            "I'll passively track your context.",
            "Ambient context on."
        ],
        ResponseKey.ambientDisabled: [
            "Background awareness paused.",
            "Ambient context off.",
            "I'll stop passively tracking your screen."
        ],

        // MARK: Memory
        ResponseKey.memorySaved: [
            "Got it, I'll remember that.",
            "Saved to memory.",
            "Noted."
        ],
        ResponseKey.memorySavedLast: [
            "Saved.",
            "Done.",
            "Got it."
        ],
        ResponseKey.memoryNothingToSave: [
            "There's nothing recent to remember.",
            "Nothing to save yet.",
            "No recent response."
        ],
        ResponseKey.memorySearchEmpty: [
            "I couldn't find anything about {query}.",
            "No results for {query}.",
            "Nothing found."
        ],
        ResponseKey.memorySearchFound: [
            "Found {count} {count_label}. For example: {snippet}.",
            "{count} {count_label}. {snippet}.",
            "Found {count}."
        ],
        ResponseKey.memorySearchNoPrev: [
            "No previous search to repeat.",
            "Nothing to search again.",
            "No prior search."
        ],
        ResponseKey.memoryUnavailable: [
            "Memory isn't available right now.",
            "Memory offline.",
            "No memory access."
        ],
        ResponseKey.memoryNone: [
            "I don't have any memories stored yet.",
            "No memories yet.",
            "Empty."
        ],
        ResponseKey.memoryRecentEmpty: [
            "No memories stored yet.",
            "Nothing remembered yet.",
            "Empty."
        ],
        ResponseKey.memoryRecentFound: [
            "Showing {count} {count_label}.",
            "{count} {count_label}.",
            "Here you go."
        ],
        ResponseKey.memoryOverlayOpened: [
            "Memory overlay open.",
            "Here's your memory.",
            "Opening memory."
        ],

        // MARK: Activity
        ResponseKey.activityUnavailable: [
            "I don't have activity history available yet.",
            "No activity history yet.",
            "Nothing tracked yet."
        ],
        ResponseKey.activityRecent: [
            "Here's your recent activity.",
            "Your recent activity:",
            "Here you go."
        ],

        // MARK: Home Assistant
        ResponseKey.homeTurnOnSuccess: [
            "Turned on {entity}.",
            "{entity} is on.",
            "Done."
        ],
        ResponseKey.homeTurnOnFailure: [
            "Couldn't turn on {entity}.",
            "Failed to turn on {entity}.",
            "That didn't work."
        ],
        ResponseKey.homeTurnOffSuccess: [
            "Turned off {entity}.",
            "{entity} is off.",
            "Done."
        ],
        ResponseKey.homeTurnOffFailure: [
            "Couldn't turn off {entity}.",
            "Failed to turn off {entity}.",
            "That didn't work."
        ],
        ResponseKey.homeEntityState: [
            "{name} is {state}.",
            "The {name} is currently {state}.",
            "{state}."
        ],
        ResponseKey.homeEntityUnknown: [
            "I don't know about {entity}.",
            "Unknown entity: {entity}.",
            "Not found."
        ],
        ResponseKey.homeBrightnessSuccess: [
            "Set {entity} to {level} percent.",
            "{entity} brightness is now {level} percent.",
            "Done."
        ],
        ResponseKey.homeBrightnessFailure: [
            "Couldn't set brightness for {entity}.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.homeColorSuccess: [
            "Changed {entity} to {color}.",
            "{entity} is now {color}.",
            "Done."
        ],
        ResponseKey.homeColorFailure: [
            "Couldn't change the color for {entity}.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.homeSceneSuccess: [
            "Activating scene: {scene}.",
            "{scene} scene activated.",
            "Done."
        ],
        ResponseKey.homeSceneFailure: [
            "Couldn't activate scene {scene}.",
            "Scene not found.",
            "That didn't work."
        ],
        ResponseKey.homeCoverOpenSuccess: [
            "Opening {entity}.",
            "{entity} is opening.",
            "Done."
        ],
        ResponseKey.homeCoverCloseSuccess: [
            "Closing {entity}.",
            "{entity} is closing.",
            "Done."
        ],
        ResponseKey.homeCoverFailure: [
            "Couldn't operate {entity}.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.homeLockSuccess: [
            "Locking {entity}.",
            "{entity} is locked.",
            "Done."
        ],
        ResponseKey.homeLockFailure: [
            "Couldn't lock {entity}.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.homeUnlockSuccess: [
            "Unlocking {entity}.",
            "{entity} is unlocked.",
            "Done."
        ],
        ResponseKey.homeUnlockFailure: [
            "Couldn't unlock {entity}.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.homeCameraOpened: [
            "Showing {entity} camera.",
            "Opening camera: {entity}.",
            "Here you go."
        ],
        ResponseKey.homeCameraUnavailable: [
            "I can't stream {entity} right now.",
            "Camera unavailable.",
            "Not available."
        ],
        ResponseKey.homeNotConfigured: [
            "Home Assistant isn't configured yet. Add your base URL and token in settings.",
            "Home Assistant not set up.",
            "Not configured."
        ],
        ResponseKey.homeAutomationTriggered: [
            "Running the {name} automation.",
            "Triggering {name} now.",
            "Done — {name} automation triggered.",
        ],
        ResponseKey.homeAutomationNotFound: [
            "I couldn't find an automation called {name}.",
            "No automation matching {name} was found.",
        ],

        // MARK: HA Camera (deep integration)

        ResponseKey.haCameraShowing: [
            "Showing {name}.",
            "Opening {name}.",
            "Here's your {name}.",
        ],
        ResponseKey.haCameraUnavailable: [
            "{name} isn't available right now. The snapshot couldn't load.",
            "Camera unavailable — can't reach {name}.",
            "Snapshot failed for {name}.",
        ],
        ResponseKey.haCameraNotFound: [
            "I couldn't find a camera matching \"{entity}\".",
            "No camera found for \"{entity}\".",
            "I don't know which camera that is.",
        ],
        ResponseKey.haCameraClosed: [
            "Camera closed.",
            "Dismissed.",
        ],
        ResponseKey.haAllCamerasOpened: [
            "Showing all cameras.",
            "Here are your cameras.",
        ],
        ResponseKey.haMotionDoor: [
            "Someone's at the door.",
            "Motion at the front door.",
        ],
        ResponseKey.haMotionGeneric: [
            "Motion detected on {name}.",
            "{name} just detected motion.",
        ],
        ResponseKey.haConnectionFailed: [
            "I can't reach Home Assistant. Check your URL and token in settings.",
            "Home Assistant connection failed.",
        ],
        ResponseKey.haAlertsMuted: [
            "Home alerts muted for one hour.",
            "Got it — no home alerts for the next hour.",
            "Home alerts silenced.",
        ],
        ResponseKey.haAlertsUnmuted: [
            "Home alerts back on.",
            "Motion and doorbell alerts resumed.",
        ],
        ResponseKey.haDiagnosticsOpened: [
            "Home Assistant diagnostics.",
            "Here's your HA status.",
        ],

        // MARK: Calendar
        ResponseKey.calendarNoEvents: [
            "Your calendar is clear for today.",
            "Nothing on your calendar today.",
            "All clear."
        ],
        ResponseKey.calendarToday: [
            "You have {count} {count_label} today. {summary}",
            "{count} events today: {summary}",
            "Today: {summary}"
        ],
        ResponseKey.calendarNextMeeting: [
            "Your next meeting is {title} at {time}.",
            "Coming up: {title} at {time}.",
            "{title} at {time}."
        ],
        ResponseKey.calendarNoUpcoming: [
            "No upcoming meetings found.",
            "Nothing scheduled coming up.",
            "All clear."
        ],
        ResponseKey.calendarReminderAdded: [
            "Reminder set: {text}.",
            "Added reminder: {text}.",
            "Done."
        ],
        ResponseKey.calendarReminderFailed: [
            "Couldn't add that reminder.",
            "Reminder failed.",
            "That didn't work."
        ],
        ResponseKey.calendarNotConfigured: [
            "Calendar access isn't available. Check Calendar permissions in System Settings.",
            "No calendar access.",
            "Permission needed."
        ],
        ResponseKey.calendarOverlayOpened: [
            "Showing your calendar.",
            "Calendar overlay open.",
            "Here you go."
        ],
        ResponseKey.tasksOverlayOpened: [
            "Showing your tasks.",
            "Tasks overlay open.",
            "Here are your tasks."
        ],
        ResponseKey.homeOverlayOpened: [
            "Opening home overview.",
            "Here's your home.",
            "Home panel ready."
        ],

        // MARK: Todoist
        ResponseKey.todoistNoTasks: [
            "You have no pending tasks in Todoist.",
            "No tasks right now.",
            "All clear."
        ],
        ResponseKey.todoistTasks: [
            "You have {count} {count_label}. {summary}",
            "{count} tasks: {summary}",
            "{summary}"
        ],
        ResponseKey.todoistTaskAdded: [
            "Added task: {text}.",
            "Task added: {text}.",
            "Done."
        ],
        ResponseKey.todoistTaskAddFailed: [
            "Couldn't add that task.",
            "Task creation failed.",
            "That didn't work."
        ],
        ResponseKey.todoistTaskCompleted: [
            "Marked as complete.",
            "Task done.",
            "Done."
        ],
        ResponseKey.todoistTaskCompleteFailed: [
            "Couldn't complete that task.",
            "That didn't work.",
            "Failed."
        ],
        ResponseKey.todoistNotConfigured: [
            "Todoist isn't configured. Add your API token in settings.",
            "Todoist not set up.",
            "Not configured."
        ],
        ResponseKey.todoistOverdueNone: [
            "No overdue tasks.",
            "You're up to date.",
            "All good."
        ],
        ResponseKey.todoistOverdue: [
            "You have {count} overdue {count_label}. {summary}",
            "Overdue: {summary}",
            "{count} overdue tasks."
        ],

        // MARK: Android
        ResponseKey.androidContinue: [
            "From your phone: {context}.",
            "Handoff from phone: {context}.",
            "{context}."
        ],
        ResponseKey.androidNothing: [
            "Nothing handed off yet.",
            "No handoff from your phone.",
            "Nothing yet."
        ],

        // MARK: UI
        ResponseKey.showContext: [
            "Here's what I know.",
            "Context loaded.",
            "Here you go."
        ],
        ResponseKey.repeatEmpty: [
            "Nothing to repeat yet.",
            "No previous response.",
            "Nothing yet."
        ],
        ResponseKey.orbMode: [
            "Orb mode on.",
            "Switching to orb mode.",
            "Orb mode."
        ],
        ResponseKey.dashboardMode: [
            "Dashboard mode on.",
            "Switching to dashboard.",
            "Dashboard mode."
        ],
        ResponseKey.overlayTestOpened: [
            "Showing status overlay.",
            "Status overlay open.",
            "Here you go."
        ],
        ResponseKey.debugHUDOn: [
            "Debug HUD on.",
            "Showing debug HUD.",
            "On."
        ],
        ResponseKey.debugHUDOff: [
            "Debug HUD off.",
            "Hiding debug HUD.",
            "Off."
        ],

        // MARK: Operating modes
        ResponseKey.modeNormal: [
            "Back to normal mode.",
            "Normal mode restored.",
            "Done."
        ],
        ResponseKey.modeConcise: [
            "Concise mode on.",
            "Switching to concise responses.",
            "Done."
        ],
        ResponseKey.modeAmbient: [
            "Ambient mode on.",
            "Running in ambient mode.",
            "Done."
        ],

        // MARK: Timeline
        ResponseKey.timelineOpened: [
            "Opening your timeline. {count} events today.",
            "Timeline ready. {count} events today.",
            "Done."
        ],
        ResponseKey.whatDidIDoToday: [
            "You've had {count} recorded events today. Here's your timeline.",
            "{count} events today. Opening timeline.",
            "Done."
        ],

        // MARK: Reasoning
        ResponseKey.reasoningOpened: [
            "Opening the reasoning panel.",
            "Showing reasoning trace.",
            "Done."
        ],

        // MARK: News
        ResponseKey.newsOpened: [
            "Opening the news overlay.",
            "Here's the latest.",
            "News overlay ready."
        ],
        ResponseKey.newsRefreshed: [
            "{count} new articles fetched.",
            "Feeds updated. {count} new items.",
            "Done — {count} new stories."
        ],
        ResponseKey.newsNoArticles: [
            "No articles found. Try refreshing the feeds.",
            "Nothing available yet. Refreshing now.",
            "Feeds appear empty — give me a moment."
        ],
        ResponseKey.newsSaved: [
            "Article saved.",
            "Saved to your reading list.",
            "Done."
        ],
        ResponseKey.newsWatchStarted: [
            "Watching {feed} for new stories.",
            "I'll notify you when {feed} publishes something new.",
            "Watch mode on for {feed}."
        ],
        ResponseKey.newsWatchStopped: [
            "Stopped watching news feeds.",
            "Watch mode off.",
            "Done."
        ],
        ResponseKey.newsSearchEmpty: [
            "Nothing found for \"{query}\" in the news archive.",
            "No news results for \"{query}\".",
            "I couldn't find any articles matching \"{query}\"."
        ],
        ResponseKey.newsSearchFound: [
            "Found {count} results. {summary}",
            "{count} articles: {summary}",
            "{summary}"
        ],
        ResponseKey.newsAlreadyOpen: [
            "News is already open.",
            "Already showing news.",
            "It's open."
        ],
        ResponseKey.newsNoRecentArticle: [
            "No recent article to save.",
            "Nothing to save yet.",
            "Open an article first."
        ],
        ResponseKey.newsWatching: [
            "Watching {channel}.",
            "Switched to {channel}.",
            "{channel} live."
        ],
        ResponseKey.newsChannelNone: [
            "No live news channel is configured yet.",
            "No channels set up.",
            "Configure a live channel in settings."
        ],
        ResponseKey.newsChannelSwitched: [
            "Switching to {channel}.",
            "Now on {channel}.",
            "{channel}."
        ],
        ResponseKey.newsChannelNotFound: [
            "{channel} isn't configured as a news channel.",
            "Channel not found.",
            "Not available."
        ],
        ResponseKey.newsChannelsNone: [
            "No news channels configured.",
            "No channels available.",
            "Configure channels in settings."
        ],
        ResponseKey.newsArticleLimited: [
            "I only have {count} {count_label} loaded.",
            "Just {count} {count_label} right now.",
            "{count} {count_label} available."
        ],
        ResponseKey.newsArticleOpening: [
            "Opening story {index}.",
            "Here's story {index}.",
            "Loading."
        ],
        ResponseKey.newsArticleBrowser: [
            "Opening in browser.",
            "Launching browser.",
            "Done."
        ],
        ResponseKey.newsArticleNoFocus: [
            "No article is currently focused.",
            "Select a story first.",
            "Nothing focused."
        ],
        ResponseKey.newsArticleClosed: [
            "Closing article.",
            "Article closed.",
            "Done."
        ],
        ResponseKey.newsArticleNone: [
            "No article is open.",
            "Nothing open right now.",
            "Open an article first."
        ],
        ResponseKey.newsSavedOpened: [
            "Showing your saved articles.",
            "Here are your saves.",
            "Reading list open."
        ],
        ResponseKey.newsFeedNotFound: [
            "I couldn't find a feed matching \"{name}\".",
            "No feed called \"{name}\".",
            "Feed not found."
        ],
        ResponseKey.newsClosed: [
            "Closing news.",
            "News closed.",
            "Done."
        ],
        ResponseKey.newsAlreadyClosed: [
            "News is already closed.",
            "It's already closed.",
            "Nothing to close."
        ],

        // MARK: UI / Overlay
        ResponseKey.overlayClosed: [
            "Closing {name}.",
            "{name} closed.",
            "Done."
        ],
        ResponseKey.overlayNoneOpen: [
            "There's no overlay open.",
            "Nothing to close.",
            "All clear."
        ],
        ResponseKey.overlayPinned: [
            "Overlay pinned.",
            "Pinned — it'll stay open.",
            "Got it, keeping it open."
        ],
        ResponseKey.overlayUnpinned: [
            "Overlay unpinned.",
            "Unpinned.",
            "It'll close normally now."
        ],
        ResponseKey.overlayLayoutReset: [
            "Layout reset.",
            "Overlays back to auto-layout.",
            "Done, layout reset."
        ],
        ResponseKey.overlayBroughtToFront: [
            "Brought to front.",
            "Done.",
            "Focused."
        ],

        ResponseKey.spatialInteractionOpen: [
            "Spatial mode active. Raise your palm to begin.",
            "Hand tracking enabled.",
            "Spatial interface on.",
        ],

        ResponseKey.spatialInteractionClose: [
            "Spatial mode off.",
            "Hand tracking disabled.",
            "Closing spatial interface.",
        ],
        ResponseKey.cameraOverlayOpen: [
            "Showing camera.",
            "Camera overlay open.",
            "Here you go."
        ],
        ResponseKey.cameraOverlayAlready: [
            "Camera is already open.",
            "Already showing.",
            "It's open."
        ],
        ResponseKey.cameraOverlayClosed: [
            "Closing camera.",
            "Camera closed.",
            "Done."
        ],
        ResponseKey.cameraOverlayAlreadyClosed: [
            "Camera is already closed.",
            "Nothing to close.",
            "All clear."
        ],

        // MARK: Status / Identity
        ResponseKey.listeningConfirm: [
            "Yes, I'm listening.",
            "I hear you.",
            "Listening."
        ],
        ResponseKey.hearingConfirm: [
            "Yes, I can hear you.",
            "Loud and clear.",
            "Yep."
        ],
        ResponseKey.timeNow: [
            "It's {time}.",
            "The time is {time}.",
            "{time}."
        ],
        ResponseKey.dateToday: [
            "Today is {date}.",
            "It's {date}.",
            "{date}."
        ],
        ResponseKey.dictationNeeded: [
            "Please enable macOS Dictation in System Settings, then say Jarvis again.",
            "Dictation is disabled. Enable it in System Settings.",
            "Enable macOS Dictation first."
        ],

        // MARK: Attention / mode debug
        ResponseKey.attentionState: [
            "Attention: {attention}. Mode: {mode}.",
            "{attention} — {mode}.",
            "{attention}, {mode}."
        ],

        // MARK: Home entities debug
        ResponseKey.homeEntitiesNone: [
            "No entities tracked yet.",
            "No home entities loaded.",
            "None yet."
        ],
        ResponseKey.homeEntitiesList: [
            "Top entities: {entities}.",
            "{entities}.",
            "{entities}"
        ],

        // MARK: System Control — Apps
        ResponseKey.appOpened: [
            "Opening {app}.",
            "Launching {app}.",
            "On it."
        ],
        ResponseKey.appNotFound: [
            "I couldn't find an app called {app}.",
            "No app named {app} found.",
            "{app} doesn't appear to be installed."
        ],
        ResponseKey.appClarify: [
            "I found a few apps matching that. Which did you mean: {apps}?",
            "Multiple matches: {apps}. Which one?",
            "Did you mean {apps}?"
        ],
        ResponseKey.appQuit: [
            "Quit {app}.",
            "Closed {app}.",
            "Done."
        ],
        ResponseKey.appHidden: [
            "Hiding {app}.",
            "{app} hidden.",
            "Done."
        ],
        ResponseKey.appActivated: [
            "Switching to {app}.",
            "Brought {app} to the front.",
            "{app}."
        ],
        ResponseKey.appsRunning: [
            "Currently running: {apps}.",
            "Open apps: {apps}.",
            "{apps}."
        ],

        // MARK: System Control — Settings
        ResponseKey.settingsOpened: [
            "Opening System Settings.",
            "System Settings is open.",
            "Done."
        ],
        ResponseKey.settingsPaneOpened: [
            "Opening {pane} settings.",
            "{pane} settings.",
            "On it."
        ],

        // MARK: System Control — Volume
        ResponseKey.volumeSet: [
            "Volume set to {level}%.",
            "Volume is now {level}%.",
            "{level}%."
        ],
        ResponseKey.volumeUp: [
            "Volume up. Now at {level}%.",
            "Louder. {level}%.",
            "{level}%."
        ],
        ResponseKey.volumeDown: [
            "Volume down. Now at {level}%.",
            "Quieter. {level}%.",
            "{level}%."
        ],
        ResponseKey.volumeMuted: [
            "Muted.",
            "Sound off.",
            "Done."
        ],
        ResponseKey.volumeUnmuted: [
            "Unmuted.",
            "Sound back on.",
            "Done."
        ],
        ResponseKey.volumeCurrent: [
            "Volume is at {level}%.",
            "Currently {level}%.",
            "{level}%."
        ],

        // MARK: System Control — Files
        ResponseKey.folderOpened: [
            "Opening {folder}.",
            "{folder} is open.",
            "Done."
        ],
        ResponseKey.folderNotFound: [
            "I couldn't find a folder called {folder}.",
            "No folder named {folder} found.",
            "Folder not found."
        ],
        ResponseKey.fileSearchResults: [
            "Found {count} file{count_label} matching \"{query}\".",
            "{count} result{count_label} for \"{query}\".",
            "Found {count}."
        ],
        ResponseKey.fileSearchEmpty: [
            "No files found matching \"{query}\".",
            "Nothing found for \"{query}\".",
            "No results."
        ],
        ResponseKey.latestDownload: [
            "Opened your latest download: {file}.",
            "Here's your most recent download: {file}.",
            "{file}."
        ],
        ResponseKey.latestDownloadNone: [
            "Your Downloads folder appears to be empty.",
            "Nothing in Downloads.",
            "No downloads found."
        ],

        // MARK: System Control — Windows
        ResponseKey.desktopShown: [
            "Showing the desktop.",
            "Desktop visible.",
            "Done."
        ],
        ResponseKey.screenLocked: [
            "Locking the screen.",
            "Screen locked.",
            "Done."
        ],
        ResponseKey.displaySlept: [
            "Display sleeping.",
            "Screen off.",
            "Done."
        ],
        ResponseKey.accessibilityNeeded: [
            "That requires Accessibility permission. Go to System Settings → Privacy & Security → Accessibility and enable Jarvis.",
            "Accessibility permission needed. Check System Settings → Privacy.",
            "Permission required."
        ],

        // MARK: System Control — Connectivity Toggles
        ResponseKey.wifiEnabled: [
            "Wi-Fi enabled.",
            "Turning Wi-Fi on.",
            "Wi-Fi is on."
        ],
        ResponseKey.wifiDisabled: [
            "Wi-Fi disabled.",
            "Turning Wi-Fi off.",
            "Wi-Fi is off."
        ],
        ResponseKey.bluetoothEnabled: [
            "Bluetooth enabled.",
            "Turning Bluetooth on."
        ],
        ResponseKey.bluetoothDisabled: [
            "Bluetooth disabled.",
            "Turning Bluetooth off."
        ],

        // MARK: Proactivity open / dismiss
        ResponseKey.proactivityOpening: [
            "Opening {source}.",
            "{source} is open.",
            "Here you go."
        ],
        ResponseKey.proactivityStoryNotFound: [
            "I can't find that story in the news feed.",
            "Story not found.",
            "Can't locate it."
        ],
        ResponseKey.proactivityNothingRecent: [
            "I don't have anything recent I can open for you.",
            "Nothing recent to open.",
            "All clear."
        ],
        ResponseKey.proactivityNothingFlagged: [
            "I haven't flagged anything recently.",
            "Nothing to open.",
            "All clear."
        ],
        ResponseKey.proactivityDismissed: [
            "Dismissed.",
            "Gone.",
            "Done."
        ],
        ResponseKey.proactivityNothingToDismiss: [
            "There's nothing to dismiss.",
            "Nothing pending.",
            "All clear."
        ],
        ResponseKey.proactivityNoSummary: [
            "I don't have a summary for that story yet.",
            "No summary available.",
            "Nothing to summarise."
        ],
        ResponseKey.proactivitySummary: [
            "Here's a summary: {excerpt}",
            "{excerpt}",
            "{excerpt}"
        ],
        ResponseKey.proactivityConfused: [
            "I'm not sure what story you mean. I haven't just told you about anything.",
            "I'm not sure what you're referring to.",
            "I don't have context for that."
        ],
        ResponseKey.proactivityPosFeedback: [
            "Good to know. I'll keep that in mind.",
            "Thanks for the feedback.",
            "Got it."
        ],
        ResponseKey.proactivityNegFeedback: [
            "Sorry about that. I'll try to do better.",
            "Noted — I'll improve.",
            "Got it."
        ],
        ResponseKey.proactivityPrefSet: [
            "Got it. I won't notify you about {category} from {source} again.",
            "Preference saved.",
            "Done."
        ],
        ResponseKey.proactivityPrefGeneric: [
            "Okay, I won't show you that type of notification.",
            "Preference saved.",
            "Done."
        ],
        ResponseKey.proactivityPrefPriority: [
            "Got it. I'll always flag {category} stories from {source}.",
            "Priority set.",
            "Done."
        ],
        ResponseKey.proactivityPrefPriorityGeneric: [
            "Okay, I'll prioritise that type of notification.",
            "Priority set.",
            "Done."
        ],

        // MARK: App / system misc
        ResponseKey.appIdentifyFailed: [
            "Let me check — I couldn't identify the app.",
            "Couldn't identify the app.",
            "Unknown app."
        ],
        ResponseKey.appPermissionRequired: [
            "Opening that app requires additional permission.",
            "Permission required to open that app.",
            "Permission needed."
        ],
        ResponseKey.settingsOpenFailed: [
            "I couldn't open System Settings.",
            "Settings failed to open.",
            "That didn't work."
        ],
        ResponseKey.volumeReadFailed: [
            "I couldn't read the volume level right now.",
            "Volume check failed.",
            "That didn't work."
        ],
        ResponseKey.finderRevealed: [
            "Revealed in Finder.",
            "Showing in Finder.",
            "Done."
        ],
        ResponseKey.appsNoneRunning: [
            "No apps appear to be running right now.",
            "Nothing running.",
            "All quiet."
        ],
        ResponseKey.summariseUnavailable: [
            "I can summarise headlines, but full article summarisation isn't wired yet.",
            "Full summarisation not available yet.",
            "Not available yet."
        ],
        ResponseKey.newsArticleNoLink: [
            "That story doesn't have a link yet.",
            "No link available.",
            "No URL."
        ],

        // MARK: GitHub
        ResponseKey.githubSummary: [
            "You have {count} GitHub notification{plural}. {top}",
            "{count} unread GitHub notification{plural}. {top}",
        ],
        ResponseKey.githubNone: [
            "No new GitHub notifications.",
            "You're all clear on GitHub.",
        ],
        ResponseKey.githubOverlayOpened: [
            "Here are your GitHub notifications.",
            "Opening GitHub.",
        ],
        ResponseKey.githubNotConfigured: [
            "GitHub isn't configured. Add your personal access token in Settings.",
            "No GitHub token set — check Settings to connect GitHub.",
        ],

        // MARK: GitHub Intelligence
        ResponseKey.githubDashboardOpened: [
            "Opening GitHub Intelligence dashboard.",
            "Here's your GitHub overview.",
        ],
        ResponseKey.githubPRsSummary: [
            "{summary}",
        ],
        ResponseKey.githubIssuesSummary: [
            "{summary}",
        ],
        ResponseKey.githubCISummary: [
            "{summary}",
        ],
        ResponseKey.githubCommitsSummary: [
            "{summary}",
        ],
        ResponseKey.githubRepoSummary: [
            "{summary}",
        ],
        ResponseKey.githubRepoCreating: [
            "Creating repository '{name}' now.",
            "On it — setting up '{name}' on GitHub.",
        ],
        ResponseKey.githubRepoCreated: [
            "{summary}",
        ],
        ResponseKey.githubNeglected: [
            "{summary}",
        ],
        ResponseKey.githubProjectStatus: [
            "{summary}",
        ],
        ResponseKey.githubCodeReviewDone: [
            "{summary}",
        ],
        ResponseKey.githubIssueCreated: [
            "Issue created. {summary}",
        ],
        ResponseKey.githubConfirmAction: [
            "{action} — say confirm to proceed, or cancel.",
        ],
        ResponseKey.githubActionRejected: [
            "Got it, cancelled.",
            "Action cancelled.",
        ],
        ResponseKey.githubError: [
            "GitHub returned an error: {error}",
            "Couldn't complete that GitHub operation: {error}",
        ],
        ResponseKey.githubWizardNextQ: [
            "{question}",
        ],

        // MARK: Shopify
        ResponseKey.shopifyOrders: [
            "You have {count} new order{plural} today. {top}.",
            "{count} order{plural} in the last 24 hours. {top}.",
        ],
        ResponseKey.shopifyNoOrders: [
            "No new orders today.",
            "Nothing new in Shopify today.",
        ],
        ResponseKey.shopifyRevenue: [
            "Today's revenue: {currency} {total} across {count} order{plural}.",
            "You've made {currency} {total} today from {count} order{plural}.",
        ],
        ResponseKey.shopifyFulfilment: [
            "{count} order{plural} need{plural_s} fulfilling.",
            "Fulfilment queue: {count} order{plural}.",
        ],
        ResponseKey.shopifyOverlay: [
            "Opening Shopify.",
            "Here's your Shopify dashboard.",
        ],
        ResponseKey.shopifyNotConfig: [
            "Shopify isn't configured. Add your credentials in Settings.",
            "No Shopify credentials — check Settings to connect.",
        ],

        // MARK: Obsidian
        ResponseKey.obsidianOverlay: [
            "Opening your vault.",
            "Here's your Obsidian vault.",
            "Your notes are up.",
        ],
        ResponseKey.obsidianNotConfigured: [
            "Obsidian vault path isn't set. Go to Settings and point Jarvis at your vault.",
            "I don't know where your vault is yet — set the path in Settings.",
        ],
        ResponseKey.obsidianSearchResult: [
            "Found {count} notes matching {query}.",
            "Here's what I found for {query} — {count} notes.",
        ],
        ResponseKey.obsidianNoResults: [
            "No notes found for {query}.",
            "I couldn't find anything about {query} in your vault.",
            "Nothing in your vault matches {query}.",
        ],
        ResponseKey.obsidianNoteRead: [
            "Here's {title}.",
            "Reading {title}.",
        ],
        ResponseKey.obsidianNoteCreated: [
            "Created {title} in your vault.",
            "Done — {title} is in your vault.",
            "New note {title} saved.",
        ],
        ResponseKey.obsidianNoteAppended: [
            "Added to {title}.",
            "Appended to {title}.",
            "Updated {title} in your vault.",
        ],
        ResponseKey.obsidianNoteNotFound: [
            "I couldn't find a note called {query}.",
            "No note matching {query} in your vault.",
        ],
        ResponseKey.obsidianRecentNotes: [
            "Here are your {count} most recently modified notes.",
            "Showing {count} recent notes.",
        ],
        ResponseKey.obsidianIndexing: [
            "Still indexing your vault. Try again in a moment.",
            "Your vault is still loading — give me a second.",
        ],

        // MARK: Apple Notes
        ResponseKey.notesOpened: [
            "Opening Apple Notes.",
            "Notes is open.",
        ],
        ResponseKey.notesCreated: [
            "Note {title} saved.",
            "I've created a note called {title}.",
        ],
        ResponseKey.notesAppended: [
            "Added that to {title}.",
            "Appended to {title}.",
        ],
        ResponseKey.notesNotFound: [
            "I couldn't find a note matching {title}.",
            "No note found called {title}.",
        ],
        ResponseKey.notesSearchResult: [
            "Found {count} {count_label}: {titles}.",
            "Here's what I found: {titles}.",
        ],
        ResponseKey.notesNoResults: [
            "No notes matched that search.",
            "Nothing found for {query}.",
        ],
        ResponseKey.notesPermissionError: [
            "I need permission to control Apple Notes. Go to System Settings → Privacy → Automation and allow Jarvis to control Notes.",
            "Apple Notes scripting is blocked. Enable it in System Settings → Privacy → Automation.",
        ],
        ResponseKey.notesNeedTitle: [
            "What should the note be called?",
            "What title should I use?",
        ],
        ResponseKey.notesNeedBody: [
            "What should I write in the note?",
            "What's the note content?",
        ],
        ResponseKey.notesNeedQuery: [
            "What should I search for in Notes?",
            "What are you looking for in Notes?",
        ],

        // MARK: Email / Apple Mail
        ResponseKey.emailOpened: [
            "Opening Mail.",
            "Mail is open.",
        ],
        ResponseKey.emailUnreadSummary: [
            "You have {count} unread email. The latest is from {sender}: {subject}.",
            "{count} unread. Latest from {sender}: {subject}.",
        ],
        ResponseKey.emailNoneFound: [
            "No emails found matching {query}.",
            "I didn't find any {query} emails.",
        ],
        ResponseKey.emailDraftCreated: [
            "Draft created to {to} with subject {subject}. Open Mail to review and send.",
            "I've started a draft to {to}. Check Mail to finish it.",
        ],
        ResponseKey.emailSearchSummary: [
            "Found {count} email about {query}. Most recent from {sender}: {subject}.",
            "{count} results for {query}. Top one is from {sender}: {subject}.",
        ],
        ResponseKey.emailImportantSummary: [
            "You have {count} important email. Most recent from {sender}: {subject}.",
            "{count} urgent or important emails. Latest: {subject} from {sender}.",
        ],
        ResponseKey.emailPermissionNeeded: [
            "I need permission to control Mail. Go to System Settings, Privacy and Security, Automation, and allow Jarvis to control Mail.",
            "Mail scripting is blocked. Enable it in System Settings under Privacy, Automation.",
        ],
        ResponseKey.emailNeedRecipient: [
            "Who should I address this email to?",
            "What's the recipient's email address?",
        ],
        ResponseKey.emailNeedSubject: [
            "What should the subject be?",
            "What's the email subject?",
        ],
        ResponseKey.emailNeedBody: [
            "What would you like to say?",
            "What should the email say?",
        ],
        ResponseKey.emailNeedQuery: [
            "What should I search for in Mail?",
            "What are you looking for in your email?",
        ],

        // MARK: LLM errors
        ResponseKey.llmTimeout: [
            "That's taking too long. I'll keep trying in the background.",
            "Request timed out.",
            "Still working on it."
        ],
        ResponseKey.llmUnavailable: [
            "My reasoning is temporarily unavailable. Try again shortly.",
            "Reasoning unavailable.",
            "Try again in a moment."
        ],
        ResponseKey.llmBlocked: [
            "I can't do that from the LLM route yet.",
            "Not available.",
            "Can't do that yet."
        ],
        ResponseKey.llmNoProblem: [
            "No problem.",
            "Okay.",
            "Got it."
        ],

        // MARK: LLM Fallback Responses
        ResponseKey.llmUnknownFallback: [
            "I'm not sure how to help with that yet.",
            "I understood the words, but not what you'd like me to do.",
            "That one's outside what I know how to handle right now."
        ],
        ResponseKey.llmUnavailableFallback: [
            "My language model isn't available right now.",
            "I can't reach the AI backend at the moment.",
            "The language model is offline — try again in a moment."
        ],
        ResponseKey.llmTimeoutFallback: [
            "That request timed out. Want to try again?",
            "The language model took too long to respond.",
            "I ran out of time waiting for a response."
        ],
        ResponseKey.llmMalformedFallback: [
            "I got an unexpected response from the language model.",
            "The model's response didn't make sense to me.",
            "Something went wrong processing that response."
        ],

        // MARK: Camera desk watch
        ResponseKey.cameraWatchDeskStarted: [
            "Watching the desk.",
            "Desk watch on.",
            "Watching."
        ],

        // MARK: Android context
        ResponseKey.androidFromPhone: [
            "From your phone: {text}",
            "{text}",
            "{text}"
        ],

        // MARK: Teach / learn phrase
        ResponseKey.teachSuccess: [
            "Got it. When you say '{phrase}', I'll {action}.",
            "Phrase learned.",
            "Done."
        ],
        ResponseKey.teachFailed: [
            "Sorry, I couldn't add that phrase.",
            "Failed to add phrase.",
            "That didn't work."
        ],
        ResponseKey.teachCommandAdded: [
            "Okay. '{phrase}' will now trigger that command.",
            "Phrase added.",
            "Done."
        ],
        ResponseKey.teachCommandFailed: [
            "I understood the command but couldn't store the phrase.",
            "Couldn't store that phrase.",
            "That didn't work."
        ],
        ResponseKey.teachCommandUnknown: [
            "I understood you want to teach me a phrase, but I couldn't figure out which command '{hint}' refers to.",
            "Command not recognised.",
            "Unknown command."
        ],

        // MARK: Proactivity / Notifications
        ResponseKey.notificationsNone: [
            "You have no pending notifications.",
            "Nothing pending.",
            "All clear."
        ],
        ResponseKey.notificationsPending: [
            "You have {count} {count_label}.",
            "{count} pending.",
            "{count}."
        ],
        ResponseKey.notificationsCleared: [
            "Notifications cleared.",
            "All dismissed.",
            "Done."
        ],
        ResponseKey.proactivityPaused: [
            "Proactive notifications paused.",
            "Paused.",
            "Done."
        ],
        ResponseKey.proactivityResumed: [
            "Proactive notifications resumed.",
            "Back on.",
            "Done."
        ],
        ResponseKey.newsNotifsMutedHour: [
            "News notifications muted for one hour.",
            "Muted for an hour.",
            "Done."
        ],
        ResponseKey.newsNotifsMuted: [
            "News notifications muted.",
            "Muted.",
            "Done."
        ],
        ResponseKey.newsNotifsUnmuted: [
            "News notifications re-enabled.",
            "Back on.",
            "Done."
        ],

        // MARK: Developer / Workspace
        ResponseKey.developerModeOn: [
            "Switching to developer mode.",
            "Debug HUD on.",
            "Dev mode."
        ],
        ResponseKey.workspaceMode: [
            "Workspace mode.",
            "Workspace.",
            "Done."
        ],

        // MARK: Listening lifecycle
        ResponseKey.listeningEnabled: [
            "I'm listening.",
            "Listening.",
            "Ready."
        ],
        ResponseKey.listeningDisabled: [
            "Going quiet.",
            "Muted.",
            "Silent."
        ],

        // MARK: Weather
        ResponseKey.weatherCurrent: [
            "{summary}",
            "Here's what it's like outside: {summary}",
        ],
        ResponseKey.weatherForecast: [
            "{summary}",
            "Here's the forecast: {summary}",
        ],
        ResponseKey.weatherRain: [
            "{summary}",
        ],
        ResponseKey.weatherNotReady: [
            "I'm still getting your location. Try again in a moment.",
            "Weather isn't ready yet — still fetching your location.",
        ],
        ResponseKey.weatherLocationDenied: [
            "I need location access to get the weather. Please allow it in System Settings.",
            "Location access is needed for weather. Check System Settings, Privacy.",
        ],

        // MARK: Help
        ResponseKey.jarvisHelp: [
            "I can help with news, weather, home automation, calendar, tasks, screen awareness, camera, memory, timers, and system control. Just ask naturally — like 'show me the news', 'turn on the lights', or 'what's the weather'.",
            "You can ask me about news, weather, your calendar, Todoist tasks, smart home devices, and I can see your screen and camera. Try things like 'what's my next meeting', 'turn off the living room lights', or 'what do you see'.",
        ],
        ResponseKey.dailyBriefing: [
            "{summary}",
            "Here's your briefing: {summary}",
        ],
        ResponseKey.dailyBriefingEmpty: [
            "Nothing to brief you on right now.",
            "All clear — no news, meetings, or tasks to report.",
        ],

        // MARK: Unknown
        ResponseKey.unknownIntent: [
            "I heard you, but I don't have an action for that yet.",
            "I'm not sure how to help with that yet.",
            "Unknown command."
        ],

        // MARK: Timers
        ResponseKey.timerSet: [
            "Timer set for {duration}.",
            "OK, {duration} timer started.",
            "{duration} — timer's running."
        ],
        ResponseKey.timerExpired: [
            "Timer's up! {name}",
            "Your {name} timer has finished.",
            "Ding — {name} timer done."
        ],
        ResponseKey.timerCancelled: [
            "Timer cancelled.",
            "{name} timer cancelled.",
            "Done, timer stopped."
        ],
        ResponseKey.timerStatus: [
            "{name}: {remaining} remaining.",
            "{remaining} left on {name}.",
            "About {remaining} to go."
        ],
        ResponseKey.timerNone: [
            "No active timers.",
            "You don't have any timers running."
        ],

        // MARK: Stopwatch
        ResponseKey.stopwatchStarted: [
            "Stopwatch started.",
            "Timer's running."
        ],
        ResponseKey.stopwatchStopped: [
            "Stopwatch stopped at {elapsed}.",
            "Time: {elapsed}."
        ],
        ResponseKey.stopwatchStatus: [
            "Stopwatch: {elapsed} elapsed.",
            "It's been {elapsed}."
        ],

        // MARK: Clipboard
        ResponseKey.clipboardContent: [
            "Your clipboard has: {text}",
            "Clipboard: {text}",
            "You've copied: {text}"
        ],
        ResponseKey.clipboardEmpty: [
            "Your clipboard is empty.",
            "Nothing in the clipboard.",
            "Clipboard is clear."
        ],
        ResponseKey.clipboardCopied: [
            "Copied to clipboard.",
            "Done, that's in your clipboard now.",
            "Copied."
        ],

        // MARK: Spotify
        ResponseKey.spotifyPlaying: [
            "Playing {query}.",
            "Looking for {query} on Spotify.",
            "On it — playing {query}."
        ],
        ResponseKey.spotifyPaused: [
            "Paused.",
            "Music paused.",
            "Pausing."
        ],
        ResponseKey.spotifyResumed: [
            "Resuming.",
            "Playing.",
            "Back to the music."
        ],
        ResponseKey.spotifySkipped: [
            "Skipped.",
            "Next track.",
            "Skipping."
        ],
        ResponseKey.spotifyBack: [
            "Going back.",
            "Previous track.",
            "Back."
        ],
        ResponseKey.spotifyNowPlaying: [
            "Now playing: {track}.",
            "This is {track}.",
            "{track} is on."
        ],
        ResponseKey.spotifyNotPlaying: [
            "Nothing is playing right now.",
            "Spotify isn't playing anything.",
            "Nothing on."
        ],
        ResponseKey.spotifyNotConfig: [
            "Spotify isn't set up. Add your token in Settings under Integrations.",
            "No Spotify token — check Settings to connect Spotify."
        ],
        ResponseKey.spotifyError: [
            "Spotify isn't responding. Is it running?",
            "Couldn't reach Spotify.",
            "Spotify error."
        ],
        ResponseKey.spotifyShuffleOn: [
            "Shuffle on.",
            "Shuffling.",
            "Shuffle enabled."
        ],
        ResponseKey.spotifyShuffleOff: [
            "Shuffle off.",
            "Shuffle disabled.",
            "Playing in order."
        ],
        ResponseKey.spotifyVolume: [
            "Spotify volume at {percent} percent.",
            "Volume set to {percent}%.",
            "{percent}%."
        ],

        // MARK: - Android Bridge
        ResponseKey.androidCalling: [
            "Calling {name}.",
            "I'll call {name} on your phone.",
            "Placing a call to {name}.",
        ],
        ResponseKey.androidMessageSent: [
            "Message sent to {name}.",
            "Done — {name} got your message.",
            "Sent.",
        ],
        ResponseKey.androidPhoneOffline: [
            "Your phone isn't connected right now.",
            "No Android device connected. Open the Jarvis app on your phone.",
            "Phone's offline — connect the Jarvis Android app and try again.",
        ],
        ResponseKey.androidPermissionRequired: [
            "Your phone needs to grant Jarvis permission for that.",
            "That needs a permission on your phone. Check the Jarvis app.",
        ],
        ResponseKey.androidContactAmbiguous: [
            "I found a few contacts named {name}. Which one?",
            "Multiple contacts match {name}. Did you mean {options}?",
        ],
        ResponseKey.androidCommandFailed: [
            "Couldn't do that on your phone: {error}",
            "Your phone returned an error: {error}",
        ],
        ResponseKey.androidNavigating: [
            "Navigation to {destination} started on your phone.",
            "Starting directions to {destination}.",
        ],
        ResponseKey.androidRinging: [
            "Ringing your phone now.",
            "Your phone should be ringing.",
            "Making your phone ring.",
        ],
        ResponseKey.androidNotificationsRead: [
            "You have {count} notification: {text}",
            "Latest from your phone — {text}",
            "No unread notifications.",
        ],
        ResponseKey.androidContactFound: [
            "Found {name}.",
            "Got it — {name} is in your contacts.",
        ],
        ResponseKey.androidStatus: [
            "Phone {connected}. {device_info}",
            "Android bridge: {connected}. {device_info}",
        ],
        // Phone battery — short, natural; answered from heartbeat cache.
        // {device} is "Galaxy Fold 6" or "your phone" when unknown; {percent}
        // is the integer battery level; {network} is "wifi" / "cellular" / etc.
        ResponseKey.phoneBatteryCharging: [
            "Your {device} is on {percent}% and charging.",
            "{device} is at {percent}% — currently charging.",
        ],
        ResponseKey.phoneBatteryDischarging: [
            "Your {device} is on {percent}% — on battery.",
            "{device} is at {percent}% and not charging.",
        ],
        ResponseKey.phoneBatteryUnknown: [
            "Your {device} is on {percent}%.",
            "{device} is at {percent}%.",
        ],
        ResponseKey.phoneBatteryOffline: [
            "Your phone is currently offline. Last seen {last_seen}.",
            "Phone's offline — last heartbeat was {last_seen}.",
        ],
        ResponseKey.androidNeedsPermission: [
            "Your phone doesn't have permission for that. Open the Jarvis app and grant the required permission.",
            "That requires a permission that hasn't been granted on your phone yet. Check the Jarvis Android app.",
            "Permission missing on your phone. Open the Jarvis app to grant access.",
        ],

        // ── Android phone event responses ─────────────────────────────────
        ResponseKey.androidNoCallerContext: [
            "I don't have a recent caller to call back.",
            "There's no recent call in my context. Who would you like to call?",
            "I can't find a recent caller. Who should I call?",
        ],
        ResponseKey.androidNoSenderContext: [
            "I'm not sure who to reply to. There's no recent message in my context.",
            "I don't have a recent sender to reply to. Who would you like to message?",
            "No recent message found. Who should I send this to?",
        ],
        ResponseKey.androidCallBackConfirm: [
            "Calling {name} back.",
            "Calling {name} back now.",
            "OK, calling {name}.",
        ],

        // ── Phase-1 call control ──────────────────────────────────────────
        ResponseKey.androidAnswerCall: [
            "Answering.",
            "Picking up.",
            "Answering the call.",
        ],
        ResponseKey.androidDeclineCall: [
            "Declining.",
            "Rejecting the call.",
            "Sending to voicemail.",
        ],
        ResponseKey.androidHangUp: [
            "Hanging up.",
            "Ending the call.",
            "Disconnecting.",
        ],
        ResponseKey.androidSpeakerOn: [
            "Speakerphone on.",
            "Switching to speakerphone.",
            "Speaker on.",
        ],
        ResponseKey.androidSpeakerOff: [
            "Speakerphone off.",
            "Turning off speakerphone.",
            "Speaker off.",
        ],
        ResponseKey.androidNoActiveCall: [
            "There's no active call on your phone.",
            "I don't see an active call right now.",
            "No call in progress.",
        ],
        ResponseKey.whatsAppVoiceCallStarting: [
            "Calling {name} on WhatsApp.",
            "Ringing {name} on WhatsApp.",
            "Starting a WhatsApp call with {name}.",
        ],
        ResponseKey.whatsAppVideoCallStarting: [
            "Starting a WhatsApp video call with {name}.",
            "Video calling {name} on WhatsApp.",
            "WhatsApp video to {name} now.",
        ],
        ResponseKey.whatsAppContactNotFound: [
            "I couldn't find {name} on WhatsApp.",
            "{name} doesn't seem to have a WhatsApp account I can reach.",
        ],
        ResponseKey.whatsAppNotInstalled: [
            "WhatsApp isn't installed on your phone.",
            "I can't reach WhatsApp on your phone — it doesn't seem to be installed.",
        ],
        ResponseKey.androidBatteryLow: [
            "Phone battery is at {level} percent.",
            "Your phone is running low — {level} percent battery.",
        ],
        ResponseKey.androidPermissionEvent: [
            "Your phone needs a permission to work properly: {description}. Open the Jarvis app on your phone to grant it.",
            "Permission needed on your phone: {description}. Check the Jarvis Android app.",
        ],

        // MARK: Conversational Jarvis (Sprint K)
        ResponseKey.progressSaved: [
            "Logged. I've added that to project memory and today's note.",
            "Done, logged to project memory.",
            "Saved. Added to today's Jarvis log.",
        ],
        ResponseKey.memoryLoggingPaused: [
            "Memory logging paused. I won't save anything from this conversation.",
            "Logging off for now.",
            "Not logging this session.",
        ],
        ResponseKey.memoryLoggingResumed: [
            "Memory logging back on.",
            "I'm logging again.",
            "Resumed.",
        ],
        ResponseKey.doNotSaveThis: [
            "This turn is off the record.",
            "Not saving this one.",
            "Understood, keeping this private.",
        ],
        ResponseKey.noProjectMemory: [
            "I don't have any project memory yet. Start by saying 'log that' after we discuss something.",
            "No project facts stored yet. Try adding your project docs path in Settings.",
            "Nothing stored for this project yet.",
        ],
        ResponseKey.showingProjectStatus: [
            "Here's what I know about the project status.",
            "Pulling up the project overview.",
        ],
        ResponseKey.todayLogNotFound: [
            "No Jarvis log found for today. Set an Obsidian vault path in Settings to enable daily notes.",
            "Today's log doesn't exist yet. I'll create it when there's something to log.",
        ],

        // MARK: Visual Intelligence / POI Surveillance (Sprint L)
        ResponseKey.surveillanceActive: [
            "Surveillance active. All camera feeds are being monitored.",
            "Visual intelligence online. Monitoring {count} feed{count_suffix}.",
            "Detection pipeline started. I'm watching.",
        ],
        ResponseKey.surveillanceStopped: [
            "Surveillance offline.",
            "Camera monitoring stopped.",
            "Visual intelligence suspended.",
        ],
        ResponseKey.sceneDescription: [
            "{description}",
            "Here's what I see: {description}",
        ],
        ResponseKey.noActivityDetected: [
            "No activity detected on any feed.",
            "All clear — nothing detected across the camera feeds.",
            "Nothing to report right now.",
        ],
        ResponseKey.threatStatusReport: [
            "Current threat level: {level}. {reason}",
            "Security status: {level}. {reason}",
        ],
        ResponseKey.motionEventReport: [
            "Last motion: {description} at {time}.",
            "{description} was detected at {time} on {camera}.",
        ],
        ResponseKey.personDetectedAlert: [
            "Person detected on {camera}.",
            "I see someone on {camera}.",
        ],
        ResponseKey.threatEscalated: [
            "Threat escalated to {level} on {camera}. {reason}",
            "Alert: {level} detected. {reason}",
        ],
        ResponseKey.cameraFocused: [
            "Showing {camera}.",
            "Focused on {camera}.",
        ],
        ResponseKey.surveillanceModeOpened: [
            "Opening surveillance dashboard.",
            "Surveillance overlay active.",
        ],
        ResponseKey.trackingActivated: [
            "High-alert tracking active. Detection frequency increased.",
            "Threat tracking engaged.",
        ],

        // Spatial Interaction Phase 1 (Sprint M)
        ResponseKey.workspaceSaved: [
            "Workspace {name} saved.",
            "Got it. I've saved your layout as {name}.",
        ],
        ResponseKey.workspaceRestored: [
            "Restoring workspace {name}.",
            "Loading your {name} layout.",
        ],
        ResponseKey.workspaceNotFound: [
            "I don't have a workspace called {name}.",
            "No workspace named {name} found.",
        ],
        ResponseKey.workspaceList: [
            "Your saved workspaces: {list}.",
            "I have these workspaces: {list}.",
        ],
        ResponseKey.noWorkspacesSaved: [
            "You haven't saved any workspaces yet.",
            "No workspaces saved. Say 'save workspace' to create one.",
        ],
        ResponseKey.widgetMoved: [
            "Widget moved {direction}.",
            "Done.",
        ],
        ResponseKey.widgetResized: [
            "Widget {action}.",
            "Done.",
        ],
        ResponseKey.widgetMinimized: [
            "Widget minimized.",
            "Collapsed.",
        ],
        ResponseKey.widgetDocked: [
            "Widget docked to the {edge}.",
            "Docked.",
        ],
        ResponseKey.widgetSnapped: [
            "Widget snapped to {zone}.",
            "Snapped.",
        ],
        ResponseKey.noWidgetHovered: [
            "No widget is in focus. Hover your hand over one first.",
            "Point at a widget first, then give the command.",
        ],
        ResponseKey.windowSnapped: [
            "{app} snapped to the {side}.",
            "Done. {app} is now on the {side}.",
        ],
        ResponseKey.windowNotFound: [
            "I couldn't find a window for {app}.",
            "No open window found for {app}.",
        ],
        ResponseKey.windowsTiled: [
            "Windows tiled.",
            "Arranged your windows side by side.",
        ],
        ResponseKey.windowFocused: [
            "Switching to {app}.",
            "Bringing {app} forward.",
        ],

        // MARK: Brain
        ResponseKey.brainOverlayOpened: [
            "Here's your brain memory browser.",
            "Opening Brain.",
            "Brain overlay is up.",
        ],
        ResponseKey.brainSummaryToday: [
            "{summary}",
        ],
        ResponseKey.brainSummaryWeek: [
            "{summary}",
        ],

        // Focus Awareness (Sprint W)
        ResponseKey.showFocus: [
            "Opening focus diagnostics.",
            "Here's your current focus state.",
            "Showing focus overlay.",
        ],
        ResponseKey.explainFocus: [
            "Here's my focus reasoning.",
            "Let me explain what I'm seeing.",
        ],
        ResponseKey.focusUnknown: [
            "I don't have a confident focus yet. Keep working and I'll track the signals.",
            "Not enough context signals yet to determine your project focus.",
        ],

        // Local Learning (Sprint AD)
        ResponseKey.learningAcknowledge: [
            "Got it, I'll remember that.",
            "Noted. I've updated my understanding.",
            "Understood, I'll use that next time.",
        ],
        ResponseKey.learningShowTraining: [
            "Opening training data.",
            "Here's your training data overview.",
        ],

        // Games
        ResponseKey.playPingPong: [
            "Game on! Raise both hands to play.",
            "Let's play! Use your hands as paddles.",
            "Ping pong time! Left hand left paddle, right hand right paddle.",
        ],
    ]

    // Sample variables for UI preview
    static let sampleVars: [String: String] = [
        "app":         "Safari",
        "query":       "meeting notes",
        "count":       "3",
        "count_label": "results",
        "snippet":     "discussed the Q3 roadmap",
        "entity":      "living room lights",
        "name":        "Thermostat",
        "state":       "on",
        "context":     "check the calendar",
        "text":        "Hello World, System Preferences",
        "device":      "microphone",
        "error":       "permission denied",
        "time":        "3:42 PM"
    ]
}
