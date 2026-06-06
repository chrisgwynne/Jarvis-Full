import Foundation

/// Tiny, table-driven matcher: lowercased substrings → typed `Intent`. No
/// LLM, no async — runs in microseconds. Phase-2 adds vision, Home
/// Assistant, and handoff phrases; anything still unmatched falls through
/// to `.unknown(text)` for a future LLM phase.
struct IntentRouter {

    /// Loose name match for Home Assistant entities. The controller hands
    /// us this closure so the router stays free of network/IO.
    var homeEntityResolver: ((String) -> String?)? = nil

    /// Like homeEntityResolver but filters to lock.* entities first, then falls back.
    var lockEntityResolver: ((String) -> String?)? = nil

    /// Primary entry point: route from a structured `ParsedCommand`.
    /// Returns `nil` when the parsed action/target combination has no
    /// known mapping; the controller then falls back to `route(text:)`
    /// for the older substring-matching path.
    func route(parsed p: ParsedCommand) -> Intent? {
        // If we can't even identify a target, the parsed path can't help.
        guard let target = p.target else { return parsedActionOnly(p) }
        // Default action when missing: "show". Most natural-language
        // commands without an explicit verb mean "show me <thing>".
        let action: CommandAction = p.action ?? .show

        switch (action, target.kind) {
        // News
        case (.show, .news), (.switchTo, .news):       return .showNews
        case (.watch, .news):                          return .watchNews
        case (.close, .news):                          return .hideNews
        case (.summarise, .news),
             (.summarise, .headlines),
             (.ask, .headlines):                       return .summariseNews
        case (.show, .headlines):                      return .showNews

        // Camera
        case (.show, .camera), (.watch, .camera):
            // If the phrase names a specific location ("show front door camera"),
            // return nil so route(_ text:) resolves the HA entity at line ~1008.
            // Bare "show camera" with no location stays on the Mac webcam.
            let t = p.normalizedText
            let hasCameraLocation = ["front door", "back door", "backyard", "driveway",
                                     "porch", "garage", "doorbell", "ring", "garden",
                                     "living room", "office", "outdoor", "indoor",
                                     "kitchen", "bedroom", "entrance", "street",
                                     "exterior", "hallway"].contains { t.contains($0) }
            if hasCameraLocation { return nil }
            return .showCameraOverlay
        case (.close, .camera):                        return .hideCamera

        // UI modes
        case (.show, .dashboard):                      return .dashboardMode
        case (.show, .orbMode):                        return .focusMode
        case (.close, .dashboard):                     return .focusMode

        // Time / status / sanity
        case (_, .time):                               return .tellTime
        case (.show, .status):                         return .showTestOverlay
        case (.show, .test):                           return .showTestOverlay
        case (_, .hearing):                            return .canYouHearMe

        // Overlays — generic
        case (.close, .overlay):                       return .closeOverlay
        case (.maximise, _):                           return .maximizeOverlay
        case (.minimise, _):                           return .minimizeOverlay

        // Articles
        case (.show, .article):
            if let n = p.ordinal { return .openStoryAt(index: n) }
            return nil
        case (.summarise, .article):
            if let n = p.ordinal { return .summariseStoryAt(index: n) }
            return .summariseNews

        // Memory / timeline / screen / chat / calendar / tasks
        case (.show, .memory):                         return .showMemoryOverlay
        case (.show, .timeline):                       return .showTimeline
        case (.show, .screen):                         return .whatAmILookingAt
        case (.show, .chat):                           return .showChat
        case (.show, .calendar):                       return .showCalendarOverlay
        case (.show, .tasks):                          return .showTasksOverlay

        // Live channel switch by name — guard against "play ping pong" being
        // misclassified as a channel (the "play " verb maps to .watch action).
        case (.watch, .channel), (.switchTo, .channel):
            let channelName = (target.label ?? "").lowercased()
            if channelName.contains("ping pong") || channelName.contains("ping-pong")
                || channelName.contains("pingpong") || channelName == "pong" {
                return .playPingPong
            }
            return .watchNewsChannel(name: target.label ?? "")

        // Apps
        case (.show, .app):
            let appLabel = target.label ?? ""
            return phoneOnlyApps.contains(appLabel.lowercased())
                ? .openAppOnPhone(name: appLabel)
                : .openApp(name: appLabel)

        // Generic close-everything fallback when target is unclear
        case (.close, .unknown):                       return .closeOverlay

        // Stop — TTS interrupt (separate from disableListening which is
        // matched by exact phrase upstream).
        case (.stop, _):                               return .stopTalking

        // Repeat last
        case (.repeatLast, _):                         return .repeatLast

        default:
            return nil
        }
    }

    /// Handle commands where we have an action but no target (e.g.
    /// bare "stop", "repeat", "next").
    private func parsedActionOnly(_ p: ParsedCommand) -> Intent? {
        switch p.action {
        case .stop:                                    return .stopTalking
        case .repeatLast:                              return .repeatLast
        case .switchTo:                                return .nextNewsChannel
        case .maximise:                                return .maximizeOverlay
        case .minimise:                                return .minimizeOverlay
        default:                                       return nil
        }
    }

    func route(_ text: String) -> Intent {
        // Normalize: lowercase, trim, strip surrounding punctuation, strip
        // common wake-word prefixes (in case the wake transcript bleeds into
        // the command STT, e.g. "jarvis show the camera").
        var t = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))
        // Collapse double spaces.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        for wake in ["jarvis,", "jarvis.", "jarvis", "hey jarvis", "ok jarvis"] {
            if t.hasPrefix(wake + " ") { t = String(t.dropFirst(wake.count + 1)); break }
            if t == wake { return .unknown(text) }
        }
        // Common "filler" lead-ins users sometimes prefix with.
        for filler in ["please ", "can you ", "could you ", "would you "] {
            if t.hasPrefix(filler) { t = String(t.dropFirst(filler.count)); break }
        }
        guard !t.isEmpty else { return .unknown(text) }

        if let url = firstURL(in: t) {
            return .openURL(url)
        }

        // ── WhatsApp call routing ───────────────────────────────────────────
        // Matches before generic "call X" so a contact name immediately
        // followed by " on whatsapp" routes to the WhatsApp call instead
        // of a standard telephony call.
        //
        // Shapes handled:
        //   "call mike on whatsapp"
        //   "phone mike on whatsapp"
        //   "ring rob on whatsapp"
        //   "whatsapp call cath"
        //   "video call cath on whatsapp"
        //   "whatsapp video call mike"
        //   "video whatsapp mike"
        //
        // Returns `.whatsAppVoiceCall(contact:)` / `.whatsAppVideoCall(contact:)`
        // with the contact name extracted minus any leading article/filler.
        if let waCall = whatsAppCallIntent(in: t) {
            return waCall
        }

        // Living documentation lookups.  Matches conversational help
        // questions and routes them to the documentation engine instead
        // of the LLM — so answers come from real capability state, never
        // hallucinated.  The full query is passed through (minus the
        // leading "how do I" / "teach me how" / "what can you do with"
        // prefix) so the engine can search example phrases too.
        for prefix in ["how do i ", "how do you ", "how can i ",
                       "teach me how to ", "what can you do with ",
                       "help me with "] {
            if t.hasPrefix(prefix) {
                let q = String(t.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !q.isEmpty {
                    return .documentationLookup(query: q)
                }
            }
        }

        // Always-on listening lifecycle — match BEFORE other patterns
        // so "sleep" / "stop listening" never get caught by other rules.
        if t == "stop listening" || t == "go quiet" || t == "go to sleep"
            || t == "sleep" || t == "disable listening"
            || t == "stop listening jarvis" || t == "disable wake word"
            || t == "be quiet jarvis" || t == "shut down listening" {
            return .disableListening
        }
        if t == "start listening" || t == "wake up" || t == "resume listening"
            || t == "enable listening" || t == "begin listening"
            || t == "wake up jarvis" || t == "you there jarvis"
            || t == "you awake" {
            return .enableListening
        }

        // Sanity-check commands — must be matched BEFORE generic patterns
        // so users get a deterministic answer for "can you hear me", etc.
        if t == "can you hear me" || t == "do you hear me"
            || t == "hear me" || t == "are you there"
            || t.contains("can you hear me") {
            return .canYouHearMe
        }
        if t == "are you listening" || t == "you listening"
            || t == "still listening" || t.contains("are you listening") {
            return .areYouListening
        }

        // Conversational closings — match BEFORE entity resolution so "goodbye"
        // never fuzzy-matches "Google" via Jaro-Winkler.
        if t == "goodbye" || t == "bye" || t == "see you" || t == "see ya"
            || t == "good night" || t == "goodnight" || t == "night"
            || t == "bye jarvis" || t == "goodbye jarvis" || t == "good night jarvis" {
            return .farewell
        }

        // Gratitude — same reasoning: "thanks" must not entity-resolve to an app.
        if t == "thanks" || t == "thank you" || t == "cheers"
            || t == "thank you very much" || t == "thanks a lot"
            || t == "thanks jarvis" || t == "thank you jarvis"
            || t == "much appreciated" {
            return .thankUser
        }

        // Time
        if t == "what time is it" || t == "what's the time" || t == "whats the time"
            || t == "tell me the time" || t == "current time" || t == "time check"
            || t.contains("what time is it") || t.contains("what's the time")
            || t.contains("whats the time") || t.contains("tell me the time")
            || t == "time" {
            return .tellTime
        }

        // Date
        if t == "what's the date" || t == "whats the date" || t == "what is the date"
            || t == "what day is it" || t == "what day is today" || t == "today's date"
            || t == "todays date" || t == "date" || t == "what month is it"
            || t.contains("what's the date") || t.contains("what date is it")
            || t.contains("what day is it") || t.contains("day of the week") {
            return .tellDate
        }

        // Developer mode
        if t == "developer mode" || t == "dev mode" || t == "show diagnostics"
            || t == "show developer mode" || t == "open developer mode"
            || t.contains("developer mode") && t.contains("switch") {
            return .developerMode
        }

        // Workspace mode (in addition to phrase store)
        if t == "workspace mode" || t == "open workspace" || t == "show workspace" {
            return .workspaceMode
        }

        // Notifications / proactivity
        if t == "what needs my attention" || t == "show notifications"
            || t == "show my notifications" || t.contains("what needs my attention")
            || t.contains("any notifications") || t.contains("anything i should know") {
            return .showNotifications
        }
        if t == "clear notifications" || t == "dismiss all notifications"
            || t == "dismiss notifications" {
            return .dismissNotifications
        }
        if t == "pause proactivity" || t == "pause notifications" || t == "stop notifying me" {
            return .pauseProactivity
        }
        if t == "resume proactivity" || t == "resume notifications" || t == "start notifying me" {
            return .resumeProactivity
        }
        if t.contains("mute news for") && (t.contains("hour") || t.contains("60")) {
            return .muteNewsForHour
        }
        if t == "mute news" || t == "stop news alerts" || t == "disable news alerts" {
            return .muteNews
        }
        if t == "unmute news" || t == "enable news alerts" || t == "resume news alerts" {
            return .unmuteNews
        }
        if t == "open that story" || t == "open the article" || t == "open that article"
            || t == "open that" {
            return .openThatStory
        }
        if t == "summarise that" || t == "summarize that" || t == "summarise the story"
            || t == "summarize the story" || t == "summarise that story"
            || t == "tell me more about that" {
            return .summariseThat
        }
        if t == "that was useful" || t == "useful" || t == "good notification"
            || t == "keep telling me this" {
            return .proactivityUseful
        }
        if t == "not useful" || t == "not helpful" || t == "that wasn't useful"
            || t == "bad notification" || t == "i didn't need to know that" {
            return .proactivityNotUseful
        }
        if t.contains("don't tell me about this") || t.contains("stop telling me about this")
            || t == "ignore stories like that" {
            return .neverTellMeAboutThis
        }
        if t.contains("always tell me about this") || t.contains("always notify me about this") {
            return .alwaysTellMeAboutThis
        }

        // Device-routing phrases
        if let m = match(t, prefix: "use microphone") { return .useMicrophone(name: m) }
        if let m = match(t, prefix: "use mic")        { return .useMicrophone(name: m) }
        if let m = match(t, prefix: "use camera")     { return .useCamera(name: m) }
        if let m = match(t, prefix: "use webcam")     { return .useCamera(name: m) }

        // Command Centre toggles — note: "show dashboard" goes to
        // .dashboardMode below so it actually switches UI; the explicit
        // "command centre" phrase still toggles fullscreen.
        if t.contains("show command centre") || t.contains("show command center") {
            return .showCommandCentre
        }
        if t.contains("hide command centre") || t.contains("hide command center")
            || t.contains("close dashboard") {
            return .hideCommandCentre
        }
        if t.contains("toggle command centre") || t.contains("toggle command center") {
            return .toggleCommandCentre
        }
        if t.contains("show context") || t.contains("what's going on")
            || t.contains("whats going on") {
            return .showContext
        }
        if t.contains("continue") && (t.contains("phone") || t.contains("android") || t.contains("mac")) {
            return .continueFromAndroid
        }

        // Session context
        if t == "repeat" || t.contains("repeat that") || t.contains("say that again")
            || t.contains("say again") {
            return .repeatLast
        }

        // UI mode
        if t.contains("focus mode") || t.contains("orb mode") || t.contains("minimal mode")
            || t.contains("hide dashboard") || t == "go to orb" {
            return .focusMode
        }
        if t.contains("show dashboard") || t.contains("dashboard mode") || t.contains("full view")
            || t.contains("show widgets") || t.contains("show diagnostics")
            || t == "open dashboard" || t == "dashboard" {
            return .dashboardMode
        }
        // Generic "show status" → status (test) overlay
        if t == "show status" || t == "show me status" || t == "open status"
            || t == "status overlay" {
            return .showTestOverlay
        }

        // Chat overlay — check before generic "show overlay" to avoid ambiguity
        if t.contains("show chat") || t.contains("open chat")
            || t.contains("show conversation") || t.contains("open conversation")
            || t.contains("show transcript") || t.contains("open transcript") {
            return .showChat
        }

        // Overlay skeleton
        if t.contains("show test overlay") || t.contains("test overlay")
            || t.contains("show overlay") || t.contains("open overlay") {
            return .showTestOverlay
        }
        // Per-overlay close — must precede the generic "close overlay" /
        // "close that" matcher so explicit names win.
        if t == "close news" || t == "hide news" || t == "dismiss news"
            || t == "close the news" || t == "hide the news"
            || t.contains("close news") || t.contains("hide news")
            || t.contains("dismiss news") || t.contains("close the news") {
            return .hideNews
        }
        // closeOverlay catches: close that / close overlay / close chat / hide chat / dismiss / hide that
        if t.contains("close overlay") || t.contains("hide overlay")
            || t.contains("close that") || t.contains("hide that")
            || t.contains("close chat") || t.contains("hide chat")
            || t.contains("dismiss that") || t.contains("dismiss overlay")
            || t == "dismiss" {
            return .closeOverlay
        }
        if t.contains("make this bigger") || t.contains("make it bigger")
            || t.contains("maximise that") || t.contains("maximize that")
            || t.contains("make bigger") || t.contains("go fullscreen") {
            return .maximizeOverlay
        }
        if t.contains("minimise that") || t.contains("minimize that")
            || t.contains("make this smaller") || t.contains("make it smaller")
            || t.contains("shrink that") {
            return .minimizeOverlay
        }
        if t.hasPrefix("pin ") || t == "pin this" || t == "pin that"
            || t.contains("pin the overlay") || t == "pin overlay" {
            return .pinOverlay
        }
        if t.hasPrefix("unpin") || t.contains("unpin the overlay") || t == "unpin overlay" {
            return .unpinOverlay
        }
        if t == "reset layout" || t.contains("reset overlay layout") || t == "snap layout"
            || t == "reset overlays" || t == "auto layout" {
            return .overlayResetLayout
        }
        if t.contains("bring to front") || t == "focus overlay" || t == "focus that" {
            return .overlayFocusTop
        }

        // Debug HUD
        if t.contains("show debug") || t.contains("debug hud") || t.contains("show hud") {
            return .showDebugHUD
        }
        if t.contains("hide debug") || t.contains("hide hud") || t.contains("close debug") {
            return .hideDebugHUD
        }

        // Memory — store
        if t.hasPrefix("remember ") {
            let payload = String(t.dropFirst("remember ".count))
                .trimmingCharacters(in: .whitespaces)
            if !payload.isEmpty { return .rememberThis(text: payload) }
        }
        // "save this" / "save that" / "remember that" → store last spoken response
        if t == "save this" || t == "save that" || t == "remember that"
            || t == "remember this" || t == "note that" || t == "note this" {
            return .rememberLast
        }

        // Memory — search
        if t.hasPrefix("search memory") || t.hasPrefix("search for")
            || t.hasPrefix("find notes about") || t.hasPrefix("find conversations about") {
            let q: String
            if t.hasPrefix("search memory for ") {
                q = String(t.dropFirst("search memory for ".count))
            } else if t.hasPrefix("search memory ") {
                q = String(t.dropFirst("search memory ".count))
            } else if t.hasPrefix("search for ") {
                q = String(t.dropFirst("search for ".count))
            } else if t.hasPrefix("find notes about ") {
                q = String(t.dropFirst("find notes about ".count))
            } else if t.hasPrefix("find conversations about ") {
                q = String(t.dropFirst("find conversations about ".count))
            } else {
                q = ""
            }
            if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                return .searchMemory(query: q.trimmingCharacters(in: .whitespaces))
            }
        }
        if t == "search again" || t == "find again" || t.contains("search that again") {
            return .searchAgain
        }

        // Identity — must come before generic "what do you know about me" entity-graph path
        if t == "what is my name" || t == "what's my name" || t == "whats my name"
            || t == "do you know my name" || t.contains("what is my name") {
            return .askMyName
        }
        if t == "who am i" || t == "who are you" || t == "what's your name"
            || t == "whats your name" || t == "what is your name"
            || t == "what are you called" || t == "tell me your name"
            || t.contains("what's your name") || t.contains("what is your name") {
            // "who are you" → assistant name; "who am i" → user name
            if t.contains("who are you") || t.contains("your name") || t.contains("you called") {
                return .askAssistantName
            }
            return .askMyName
        }
        if t.contains("what do you know about me") || t.contains("tell me what you know about me")
            || t.contains("what have you learned about me") || t.contains("what do you know of me") {
            return .askPersonalFacts
        }

        // Memory — recall
        if t == "what do you remember" || t == "what have you remembered"
            || t == "what do you remember about" {
            return .whatDoYouRemember
        }
        if t.contains("show me my memories") || t.contains("my memories") {
            return .showMemoryOverlay
        }
        if t.contains("show recent memories") || t.contains("recent memories") {
            return .showRecentMemories
        }
        if t.contains("show memory") || t.contains("open memory") || t.contains("memory overlay") {
            return .showMemoryOverlay
        }

        // Activity / context recall
        if t.contains("what was i doing") || t.contains("what was i working on")
            || t.contains("what have i been doing") || t.contains("what have i been working on")
            || t.contains("where did i leave off") || t.contains("where did we leave off") {
            return .whatWasIDoingEarlier
        }
        if t.contains("show recent activity") || t.contains("recent activity")
            || t.contains("recent sessions") || t.contains("what happened recently") {
            return .showRecentActivity
        }

        // Screen awareness
        if t.contains("what am i looking at") || t.contains("what's on my screen")
            || t.contains("whats on my screen") || t.contains("what's on screen")
            || t.contains("whats on screen") {
            return .whatAmILookingAt
        }
        if t.contains("read my screen") || t.contains("read the screen")
            || t.contains("read screen") {
            return .readMyScreen
        }
        if t.contains("summarise this screen") || t.contains("summarize this screen")
            || t.contains("summarise my screen") || t.contains("summarize my screen")
            || t.contains("summarise the screen") {
            return .summariseScreen
        }
        if t == "capture screen" || t == "screenshot" || t == "take a screenshot"
            || t.contains("capture the screen") || t.contains("snap the screen") {
            return .captureScreen
        }
        if t.contains("watch this screen") || t.contains("watch my screen")
            || t.contains("monitor my screen") || t.contains("keep watching") {
            return .watchThisScreen
        }
        if t.contains("stop watching") || t.contains("stop monitoring screen")
            || t.contains("stop screen watch") {
            return .stopWatchingScreen
        }
        if t.contains("what app") || t.contains("which app") || t.contains("what application")
            || t.contains("which application") || t.contains("what am i using") {
            return .whatAppAmIUsing
        }
        if t.contains("what text") || t.contains("what does the screen say")
            || t.contains("read the text") || t.contains("what words") {
            return .whatTextDoYouSee
        }
        if t.contains("show screen") || t.contains("screen overlay") || t.contains("screen awareness") {
            return .showScreenOverlay
        }

        // Ambient context
        if t.contains("what am i working on") || t.contains("what are we working on")
            || t.contains("what am i doing") || t.contains("what's my current task") {
            return .whatAmIWorkingOn
        }

        // Focus awareness (Sprint W)
        if t.contains("show focus") || t.contains("context graph") || t.contains("focus state")
            || t.contains("recent work sessions") {
            return .showFocus
        }
        if t.contains("explain") && (t.contains("focus") || t.contains("context"))
            || t.contains("why do you think") || t.contains("what project am i focused on")
            || t.contains("what are you basing") || t.contains("why that project") {
            return .explainCurrentFocus
        }
        if t.contains("what failed") || t.contains("what's the error") || t.contains("what error")
            || t.contains("what broke") || t.contains("any errors") || t.contains("show errors") {
            return .whatFailedOnScreen
        }
        if t.contains("what changed") || t.contains("what's different") {
            return .whatChangedOnScreen
        }
        if (t.contains("watch this") || t.contains("monitor this") || t.contains("keep an eye on this")
            || t.contains("watch this build") || t.contains("start watching"))
            && !t.contains("screen") {
            return .watchThis
        }
        if t.contains("stop watching") && !t.contains("screen") {
            return .stopWatching
        }
        if t.contains("enable ambient") || t.contains("start ambient") || t.contains("enable background awareness") {
            return .enableAmbientContext
        }
        if t.contains("disable ambient") || t.contains("pause ambient") || t.contains("disable background awareness") {
            return .disableAmbientContext
        }
        if t.contains("ambient context") || t.contains("ambient debug") || t.contains("context debug") {
            return .showAmbientContextOverlay
        }
        if t.contains("runtime diagnostics") || t.contains("subsystem health") || t.contains("system runtime") {
            return .showRuntimeDiagnostics
        }
        if t.contains("speech latency") || t.contains("latency diagnostics") || t.contains("pipeline timing") {
            return .showSpeechLatency
        }
        if t.contains("voice lab") || t.contains("tts comparison") || t.contains("voice benchmark") {
            return .showVoiceLab
        }
        if t.contains("ping pong") || t.contains("pingpong") || t.contains("ping-pong")
            || t == "pong" || t.contains("play pong") {
            return .playPingPong
        }
        if t.contains("show brain") || t.contains("open brain") || t.contains("brain overlay")
            || t.contains("brain memory") || t == "brain" {
            return .showBrainOverlay
        }
        if t.contains("brain summary") || t.contains("what do you remember today") || t.contains("brain today") {
            return .brainSummaryToday
        }
        if t.contains("brain week") || t.contains("weekly brain") || t.contains("what have you learned this week") {
            return .brainSummaryWeek
        }
        if t.contains("spatial mode") || t.contains("hand mode") || t.contains("gesture mode")
            || t.contains("spatial interaction") || t.contains("hand tracking mode")
            || t == "open spatial" || t == "launch spatial" || t == "spatial interface" {
            return .showSpatialInteraction
        }
        if t.contains("close spatial") || t.contains("exit spatial")
            || t.contains("close hand mode") || t.contains("exit gesture mode")
            || t.contains("disable spatial") {
            return .hideSpatialInteraction
        }

        // Camera overlay — accept "show my camera", "show the camera",
        // "show me the camera", "where's my camera", "open camera", etc.
        if t == "hide camera" || t == "close camera"
            || t == "hide my camera" || t == "close my camera"
            || t == "hide the camera" || t == "close the camera"
            || t == "dismiss camera" || t == "dismiss the camera"
            || t.contains("close camera") || t.contains("hide camera")
            || t.contains("dismiss camera") || t.contains("close the camera")
            || t.contains("hide the camera") {
            return .hideCamera
        }
        if t.contains("camera overlay") || t.contains("show camera overlay")
            || t.contains("open camera") || t == "camera"
            || t.contains("show camera") || t.contains("show my camera")
            || t.contains("show me camera") || t.contains("show me the camera")
            || t.contains("show me my camera") || t.contains("show the camera")
            || t.contains("show webcam") || t.contains("show my webcam")
            || t.contains("show the webcam") || t.contains("open the camera")
            || t.contains("open my camera") || t.contains("where's my camera")
            || t.contains("wheres my camera") {
            // Don't fire when user is asking to STOP camera things.
            if !t.contains("stop") { return .showCameraOverlay }
        }

        // Vision / camera — describe-scene commands. Listed before generic turn-on/off
        // so "what can you see" never falls through to `.unknown`.
        //
        // NOTE: `t` is already TranscriptNormalizer-normalized before reaching here,
        // so mid-sentence fillers ("the", "a", "my") are stripped. We must check both
        // the original phrase form AND the post-normalization form.
        // e.g. "describe the view" → normalized → "describe view"; check both.
        if t.contains("what can you see") || t.contains("what do you see")
            || t.contains("what can you tell me about what you see")
            || t.contains("what can you tell about what you see")   // "me" stripped by normalizer
            || t.contains("describe what you see") || t.contains("describe what you can see")
            || t.contains("describe the view") || t.contains("describe view")  // post-norm form
            || t.contains("describe scene")
            || t.contains("what is in front of you") || t.contains("what's in front of you")
            || t.contains("look at this") || t.contains("look around")
            // Additional natural phrasings ("what it sees", "what does the camera see", etc.)
            || t.contains("what it sees") || t.contains("what does it see")
            || t.contains("what can it see") || t.contains("what is it looking at")
            || t.contains("what does the camera see") || t.contains("what does camera see")
            || t.contains("camera sees")
            || t.contains("what's on camera") || t.contains("what is on camera")
            || t.contains("what do you see on camera") || t.contains("describe the camera")
            || t.contains("describe camera")   // post-norm form
            || t.contains("what are you seeing") || t.contains("what are you looking at")
            || t.contains("what do you currently see")
            || t == "see" || t == "look" || t == "describe" {
            return .whatCanYouSee
        }
        if t.contains("describe the person") || t.contains("describe who")
            || t.contains("who is in front") || t.contains("who's in front")
            || t.contains("describe me") || t.contains("describe the man")
            || t.contains("describe the woman") || t.contains("describe the human")
            || t.contains("what do i look like") || t.contains("what does the person look like")
            || t.contains("tell me about the person") || t.contains("what is the person wearing")
            || t.contains("what's the person wearing") {
            return .describePerson
        }
        if t.contains("what's on my desk") || t.contains("what is on my desk")
            || t.contains("what's on the desk") || t.contains("what is on the desk")
            || t.contains("what's on the table") || t.contains("what is on the table")
            || t.contains("describe my desk") || t.contains("describe the desk")
            || t.contains("what do you see on my desk") || t.contains("what's in front of me")
            || t.contains("what is in front of me") || t.contains("describe the objects")
            || t.contains("what objects") || t.contains("list what you see")
            || t.contains("what items") {
            return .whatIsOnDesk
        }
        if t == "look at this" || t.hasPrefix("look at ") {
            return .lookAtThis
        }
        if t.hasPrefix("read this") || t == "read" {
            return .readThis
        }
        if t == "scan this" || t.contains("scan the") || t.hasPrefix("scan ") {
            return .scanThis
        }
        if t.contains("am i holding") || t.contains("in my hand") || t.contains("in my hands")
            || t.contains("have i got") || t.contains("what do i have in my hand")
            || t.contains("am i carrying") || t.contains("what's that in my hand")
            || t.contains("what is that in my hand") {
            return .whatAmIHolding
        }
        if t.contains("is anyone there") || t.contains("anyone home")
            || t.contains("who's there") || t.contains("whos there")
            || t.contains("can you see anyone") || t.contains("is there anyone")
            || t.contains("am i on camera") || t.contains("am i visible") {
            return .isAnyoneThere
        }
        // Sprint L — surveillance / POI vision routing
        if t.contains("surveillance") || t.contains("show cameras") || t.contains("cctv")
            || t.contains("show camera feeds") || t.contains("camera dashboard")
            || t == "the machine" || t.contains("show the machine") {
            return .showSurveillanceMode
        }
        if t.contains("start surveillance") || t.contains("activate surveillance")
            || t.contains("start monitoring") || t.contains("enable surveillance") {
            return .startSurveillance
        }
        if t.contains("stop surveillance") || t.contains("disable surveillance") {
            return .stopSurveillance
        }
        if t.contains("describe the scene") || t.contains("what do you see")
            || t.contains("describe what you see") || t.contains("tell me what you see") {
            return .describeVisualScene
        }
        if t.contains("any people outside") || t.contains("anyone outside")
            || t.contains("any people detected") || t.contains("see any people")
            || t.contains("spot anyone") {
            return .anyPeopleDetected
        }
        if t.contains("who is at the door") || t.contains("who's at the door")
            || t.contains("anyone at the door") {
            return .whoIsAtLocation(location: "door")
        }
        if t.contains("threat status") || t.contains("threat level")
            || t.contains("security status") || t.contains("anything suspicious") {
            return .showThreatStatus
        }
        if t.contains("what moved") || t.contains("last motion")
            || t.contains("latest motion") || t.contains("motion event") {
            return .lastMotionEvent
        }
        if t.contains("track that") || t.contains("activate threat tracking")
            || t.contains("high alert mode") || t.contains("watch mode on") {
            return .activateThreatTracking
        }
        if t.contains("watch the desk") || t.contains("monitor the desk")
            || t.contains("watch my desk") {
            return .watchTheDesk
        }
        if t.contains("watch the room") || t.contains("watch my room")
            || t.contains("monitor the room") || t.contains("watch the office") {
            return .watchRoom
        }
        if t.contains("stop watching camera") || t.contains("stop camera watch")
            || t.contains("stop monitoring camera") {
            return .stopWatchingCamera
        }
        if t.contains("take a photo") || t.contains("take a picture")
            || t.contains("snap a photo") || t.contains("capture image")
            || t == "capture camera" || t == "capture" {
            return .takePhoto
        }

        // Operating modes
        if t == "normal mode" || t == "back to normal" || t == "default mode"
            || t.contains("turn off silent") || t.contains("disable silent") {
            return .modeNormal
        }
        if t == "concise mode" || t.contains("be concise") || t.contains("shorter responses")
            || t.contains("brief mode") {
            return .modeConcise
        }
        if t == "silent mode" || t.contains("go silent") || t.contains("no talking")
            || t.contains("text only") {
            return .modeSilent
        }
        // "stop speaking" / "shut up" / "be quiet" → stop TTS, don't enter silent mode
        if t == "stop speaking" || t == "shut up" || t == "be quiet"
            || t == "stop talking" {
            return .stopTalking
        }
        if t == "ambient mode" || t.contains("go ambient") || t.contains("background mode") {
            return .modeAmbient
        }

        // Timeline
        if t.contains("what did i do today") || t.contains("what have i done today")
            || t.contains("show today") || t.contains("today's activity") {
            return .whatDidIDoToday
        }
        if t.contains("open timeline") || t.contains("show timeline")
            || t.contains("recent activity") && t.contains("timeline")
            || t == "timeline" {
            return .showTimeline
        }

        // Reasoning / debug
        if t.contains("why did you do that") || t.contains("why did you say that")
            || t.contains("explain that") || t.contains("explain what you did") {
            return .whyDidYouDoThat
        }
        if t.contains("show reasoning") || t.contains("debug reasoning")
            || t.contains("open reasoning") || t.contains("reasoning overlay") {
            return .showReasoning
        }

        // Attention
        if t.contains("what's my attention state") || t.contains("what is my attention state")
            || t.contains("show attention") {
            return .showAttentionState
        }

        // Entity graph
        if t.contains("show entity graph") || t.contains("open entity graph")
            || t.contains("what do you know about") {
            return .showEntityGraph
        }

        // News — article overlay close
        if t == "close article" || t == "close web" || t == "close webpage"
            || t == "close page" || t == "hide article" {
            return .hideArticle
        }

        // News — open story by ordinal ("open story one", "open article 2",
        // "show article three", "open first story", "open the first story").
        if let n = parseStoryOrdinal(in: t, verbs: ["open ", "show "]) {
            return .openStoryAt(index: n)
        }
        if t.hasPrefix("summarise story ") || t.hasPrefix("summarize story ")
            || t.hasPrefix("summarise article ") || t.hasPrefix("summarize article ") {
            if let n = parseStoryOrdinal(in: t, verbs: ["summarise ", "summarize "]) {
                return .summariseStoryAt(index: n)
            }
        }

        // Open the currently-focused article externally.
        if t == "open in browser" || t == "open this in browser"
            || t == "open in safari" || t == "open this in safari"
            || t == "open article in browser" {
            return .openInBrowser
        }

        // Summarise news — explicit only. "show news" must NOT route here.
        if t == "summarise news" || t == "summarize news"
            || t == "summarise the news" || t == "summarize the news"
            || t == "summarise headlines" || t == "summarize headlines"
            || t == "what are the headlines" || t == "read the headlines"
            || t == "read headlines" || t == "read me the news" {
            return .summariseNews
        }

        // News channel control
        if t == "next news channel" || t == "next channel" || t == "next news"
            || t == "another news channel" {
            return .nextNewsChannel
        }
        if t == "previous news channel" || t == "previous channel"
            || t == "last news channel" || t == "go back to last channel" {
            return .prevNewsChannel
        }
        // "watch news" / "play news" → default channel
        if t == "watch news" || t == "play news" || t == "start news"
            || t == "play the news" {
            return .watchNews
        }
        // "watch Bloomberg" / "show Bloomberg" / "switch to BBC News" — must
        // not greedily catch "watch news" (handled above).
        if t.hasPrefix("watch ") || t.hasPrefix("switch to ")
            || t.hasPrefix("show me ") {
            let prefix: String
            if t.hasPrefix("watch ")      { prefix = "watch " }
            else if t.hasPrefix("switch to ") { prefix = "switch to " }
            else                          { prefix = "show me " }
            let rest = String(t.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            // Skip non-channel phrases.
            let blocklist: Set<String> = ["news", "feed", "feeds", "the news"]
            if !rest.isEmpty && !blocklist.contains(rest) {
                // Heuristic: phrase must be 1-3 words to feel like a name.
                let wordCount = rest.split(separator: " ").count
                if wordCount <= 4 {
                    return .watchNewsChannel(name: rest)
                }
            }
        }

        if t.contains("refresh news") || t.contains("update news") || t.contains("fetch news") {
            return .refreshNews
        }
        if t.contains("stop watching news") || t.contains("stop news watch")
            || t.contains("unwatch news") {
            return .stopWatchingNews
        }
        if t.hasPrefix("watch ") && (t.contains("feed") || t.contains("bbc")
            || t.contains("bloomberg") || t.contains("guardian") || t.contains("verge")
            || t.contains("reuters") || t.contains("hacker")) {
            let name = String(t.dropFirst("watch ".count)).trimmingCharacters(in: .whitespaces)
            return .watchFeed(name: name)
        }
        if t.contains("find news about ") || t.contains("search news for ")
            || t.contains("find articles about ") {
            let q: String
            if t.contains("find news about ") {
                q = String(t.components(separatedBy: "find news about ").last ?? "")
            } else if t.contains("search news for ") {
                q = String(t.components(separatedBy: "search news for ").last ?? "")
            } else {
                q = String(t.components(separatedBy: "find articles about ").last ?? "")
            }
            if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                return .searchNews(query: q.trimmingCharacters(in: .whitespaces))
            }
        }
        if t.contains("saved news") || t.contains("saved articles")
            || t.contains("my saved articles") || t.contains("bookmark") {
            return .showSavedNews
        }
        if t.contains("save this article") || t.contains("save that article")
            || t.contains("bookmark this") || t.contains("save this story") {
            return .saveNewsArticle
        }
        // Label-specific news — check before generic "show news"
        if (t.contains("tech news") || t.contains("technology news")) {
            return .showNewsLabel(label: "technology")
        }
        if t.contains("uk news") || t.contains("british news") {
            return .showNewsLabel(label: "uk")
        }
        if t.contains("world news") || t.contains("international news")
            || t.contains("global news") {
            return .showNewsLabel(label: "world")
        }
        if t.contains("business news") || t.contains("finance news")
            || t.contains("financial news") || t.contains("markets news") {
            return .showNewsLabel(label: "finance")
        }
        if t.contains("ai news") || t.contains("artificial intelligence news") {
            return .showNewsLabel(label: "ai")
        }
        // "what's happening" alone is far too broad — it matches questions about
        // calendar, home devices, the build, etc.  Only trigger news when "happening"
        // is explicitly followed by a news qualifier.
        if t.contains("show news") || t.contains("open news") || t == "news"
            || t.contains("today's news") || t.contains("todays news")
            || t.contains("what's in the news") || t.contains("whats in the news")
            || t.contains("latest news") || t.contains("news overlay")
            || t.contains("summarise the news") || t.contains("summarize the news")
            || t.contains("what's happening in the news")
            || t.contains("whats happening in the news")
            || t.contains("headlines") {
            return .showNews
        }

        // Personality settings
        if t.contains("open personality") || t.contains("show personality")
            || t.contains("edit personality") || t.contains("personality settings")
            || t.contains("jarvis identity") || t.contains("open identity") {
            return .showPersonalitySettings
        }
        if t.contains("reload personality") || t.contains("refresh personality")
            || t.contains("update personality") {
            return .reloadPersonality
        }

        // Response playbook
        if t.contains("show response playbook") || t.contains("open response settings")
            || t.contains("change how you respond") || t.contains("edit responses")
            || t.contains("say ") && t.contains(" when ") {
            return .showResponsePlaybook
        }

        // TTS interrupt
        if t.contains("stop talking") || t.contains("be quiet") || t.contains("shut up") {
            return .stopTalking
        }

        // Status
        if t.contains("status") || t.contains("system status") || t.contains("how are you") {
            return .status
        }

        // Home Assistant — extended commands
        // Brightness: "dim the living room to 40" / "set brightness to 70 percent"
        if let (entity, level) = parseSetBrightness(t) {
            return .homeSetBrightness(entity: entity, level: level)
        }
        // Color: "make the bedroom lamp red" / "set the desk lamp to blue"
        if let (entity, color) = parseSetColor(t) {
            return .homeSetColor(entity: entity, color: color)
        }
        // Scene: "activate movie scene" / "scene: dinner"
        if t.hasPrefix("activate scene ") || t.hasPrefix("scene ") || t.hasPrefix("set scene ") {
            let name: String
            if t.hasPrefix("activate scene ") { name = String(t.dropFirst("activate scene ".count)) }
            else if t.hasPrefix("set scene ")  { name = String(t.dropFirst("set scene ".count)) }
            else                               { name = String(t.dropFirst("scene ".count)) }
            if !name.isEmpty { return .homeActivateScene(name: name) }
        }
        // Automation: "run automation X" / "trigger automation X" / "activate automation X"
        if t.contains("automation") && (t.hasPrefix("run ") || t.hasPrefix("trigger ")
            || t.hasPrefix("activate ")) {
            let name = t
                .replacingOccurrences(of: "run the ", with: "")
                .replacingOccurrences(of: "run automation ", with: "")
                .replacingOccurrences(of: "run automation", with: "")
                .replacingOccurrences(of: "trigger automation ", with: "")
                .replacingOccurrences(of: "trigger automation", with: "")
                .replacingOccurrences(of: "activate automation ", with: "")
                .replacingOccurrences(of: "activate automation", with: "")
                .replacingOccurrences(of: "automation", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .homeRunAutomation(name: name.isEmpty ? "unknown" : name)
        }

        // Cover: "open the garage" / "close the blinds"
        if t == "open the garage" || t == "open garage" || t == "open the blinds"
            || t == "open blinds" || t.hasPrefix("open the blind")
            || t.hasPrefix("open cover ") || t.hasPrefix("open shutter") {
            let entity = extractCoverEntity(from: t, action: "open")
            return .homeOpenCover(entity: entity)
        }
        if t == "close the garage" || t == "close garage" || t == "close the blinds"
            || t == "close blinds" || t.hasPrefix("close the blind")
            || t.hasPrefix("close cover ") || t.hasPrefix("close shutter") {
            let entity = extractCoverEntity(from: t, action: "close")
            return .homeCloseCover(entity: entity)
        }
        // Lock/unlock
        if t == "lock the door" || t == "lock door" || t == "lock front door"
            || t == "lock the front door" {
            return .homeLock(entity: "lock.front_door")
        }
        if t.hasPrefix("lock "), let entity = resolveEntity(in: String(t.dropFirst("lock ".count))) {
            return .homeLock(entity: entity)
        }
        if t == "unlock the door" || t == "unlock door" || t == "unlock front door"
            || t == "unlock the front door" {
            return .homeUnlock(entity: "lock.front_door")
        }
        if t.hasPrefix("unlock "), let entity = resolveEntity(in: String(t.dropFirst("unlock ".count))) {
            return .homeUnlock(entity: entity)
        }
        // HA Camera overlay — close / all / diagnostics (no entity payload needed)
        if t == "close camera" || t == "close the camera" || t == "hide camera"
            || t == "dismiss camera" || t.hasPrefix("close ") && t.contains("camera") {
            return .homeCloseCamera
        }
        if t == "show all cameras" || t == "all cameras" || t == "camera grid"
            || t == "show cameras" || t == "camera overview" || t == "show my cameras" {
            return .homeShowAllCameras
        }
        if t.contains("ha diagnostics") || t.contains("home assistant diagnostics")
            || t.contains("camera diagnostics") {
            return .homeShowHADiagnostics
        }
        if t.contains("mute home alerts") || t.contains("mute doorbell")
            || t.contains("mute motion alerts") || t.contains("mute camera alerts")
            || t.contains("quiet the doorbell") || t.contains("stop camera alerts") {
            return .homeMuteAlerts
        }
        if t.contains("unmute home alerts") || t.contains("unmute doorbell")
            || t.contains("unmute motion") || t.contains("resume home alerts") {
            return .homeUnmuteAlerts
        }

        // HA Camera overlay — entity-specific: "show front door camera", "show the ring"
        // Routes to the new .homeShowCameraOverlay intent (opens .haCamera overlay).
        let cameraKeywords = ["camera", "doorbell", "ring", "front door", "backyard",
                              "driveway", "porch", "garden", "garage", "living room camera"]
        let hasCameraWord  = cameraKeywords.contains { t.contains($0) }
        let hasShowVerb    = t.hasPrefix("show ") || t.hasPrefix("open ") ||
                             t.hasPrefix("pull up ") || t.hasPrefix("bring up ")
        if hasShowVerb && hasCameraWord {
            var name = t
            for prefix in ["show the ", "show ", "open the ", "open ", "pull up the ", "pull up ", "bring up the ", "bring up "] {
                if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)); break }
            }
            name = name.replacingOccurrences(of: " camera", with: "")
                       .trimmingCharacters(in: .whitespaces)
            return .homeShowCameraOverlay(entity: name)
        }

        // Generic turn on/off
        if t.hasPrefix("turn on "),
           let entity = resolveEntity(in: String(t.dropFirst("turn on ".count))) {
            return .homeTurnOn(entity: entity)
        }
        if t.hasPrefix("turn off "),
           let entity = resolveEntity(in: String(t.dropFirst("turn off ".count))) {
            return .homeTurnOff(entity: entity)
        }
        if t.hasPrefix("status of "),
           let entity = resolveEntity(in: String(t.dropFirst("status of ".count))) {
            return .homeQueryEntity(entity: entity)
        }

        // ── Natural entity-state queries ("is the front door locked?") ───────
        // Handles: "is X locked/unlocked/on/off/open/closed/armed/home/away"
        // Normalized text has already stripped "the"/"a"/"my" mid-sentence.
        let lockSuffixes   = [" locked", " unlocked"]
        let genericSuffixes = [" on", " off", " open", " closed", " armed", " disarmed",
                                " running", " home", " away", " active", " inactive"]
        // Common lock entity hardcodes — used when entity cache is empty at query time.
        let commonLockFallbacks: [(String, String)] = [
            ("front door", "lock.front_door"),
            ("back door",  "lock.back_door"),
            ("garage",     "lock.garage_door"),
            ("door",       "lock.front_door"),
        ]
        if t.hasPrefix("is ") {
            let body = String(t.dropFirst("is ".count))
            // Lock-domain query — prefer lock.* entity, then hardcoded fallback
            for s in lockSuffixes {
                if body.hasSuffix(s) {
                    let phrase = String(body.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
                    if !phrase.isEmpty {
                        let entity = lockEntityResolver?(phrase)
                            ?? resolveEntity(in: phrase)
                            ?? commonLockFallbacks.first(where: { phrase.contains($0.0) })?.1
                        if let entity { return .homeQueryEntity(entity: entity) }
                    }
                }
            }
            // Generic entity state query
            for s in genericSuffixes {
                if body.hasSuffix(s) {
                    let phrase = String(body.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
                    if !phrase.isEmpty, let entity = resolveEntity(in: phrase) {
                        return .homeQueryEntity(entity: entity)
                    }
                }
            }
        }
        // "check the lock" / "check front door lock"
        if t.hasPrefix("check ") {
            let phrase = String(t.dropFirst("check ".count))
                .replacingOccurrences(of: " lock", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !phrase.isEmpty {
                let entity = lockEntityResolver?(phrase)
                    ?? resolveEntity(in: phrase)
                    ?? commonLockFallbacks.first(where: { phrase.contains($0.0) })?.1
                if let entity { return .homeQueryEntity(entity: entity) }
            }
        }
        // Home overlay — explicit overlay/panel/grid requests before homeStatus catch-all
        if (t.contains("home overlay") || t.contains("home panel") || t.contains("home grid")
            || t.contains("smart home panel") || t.contains("smart home overlay")
            || t.contains("show devices") || t.contains("open devices")
            || t == "open home" || t == "my devices" || t == "show my devices") {
            return .showHomeOverlay
        }
        if t.contains("home status") || t.contains("show home") || t.contains("what's at home") {
            return .homeStatus
        }

        // Calendar overlay
        if t == "show calendar" || t == "open calendar" || t == "calendar"
            || t.contains("my calendar") || t.contains("calendar overlay")
            || t.contains("show calendar") || t.contains("open calendar")
            || t.contains("today's events") || t.contains("what are my events")
            || t.contains("what is on my calendar") {
            return .showCalendarOverlay
        }
        if t == "next meeting" || t.contains("when is my next meeting")
            || t.contains("next appointment") || t.contains("next event")
            || t.contains("when is my next appointment") {
            return .nextMeeting
        }
        if t.contains("meetings today") || t.contains("what is on my calendar")
            || t.contains("what do i have today") || t.contains("schedule today")
            || t.contains("appointments today") || t.contains("what have i got today")
            || t.contains("today meetings") {
            return .meetingsToday
        }
        if t.hasPrefix("remind me to ") || t.hasPrefix("remind me about ") {
            let payload = t.hasPrefix("remind me to ")
                ? String(t.dropFirst("remind me to ".count))
                : String(t.dropFirst("remind me about ".count))
            if !payload.isEmpty { return .addReminder(text: payload) }
        }
        if t.hasPrefix("add reminder ") || t.hasPrefix("set a reminder ") {
            let payload = t.hasPrefix("set a reminder ")
                ? String(t.dropFirst("set a reminder ".count))
                : String(t.dropFirst("add reminder ".count))
            if !payload.isEmpty { return .addReminder(text: payload) }
        }

        // Tasks overlay
        if t == "show tasks" || t == "open tasks" || t == "my tasks"
            || t == "task list" || t == "show task list" || t == "tasks overlay"
            || t == "show my tasks" || t.contains("show my tasks") || t.contains("show tasks")
            || t.contains("open tasks") || t.contains("my to do list") || t.contains("todo list")
            || t.contains("what are my tasks") {
            return .showTasksOverlay
        }
        if t.contains("what tasks do i have")
            || t.contains("what do i need to do") || t.contains("what is on my to do list")
            || t.contains("read my tasks") || t.contains("open my task list") {
            return .showTasksOverlay
        }
        if t.hasPrefix("add task ") {
            return .addTask(text: String(t.dropFirst("add task ".count)))
        }
        if t.hasPrefix("complete task ") || t.hasPrefix("finish task ") || t.hasPrefix("done with ") {
            let payload: String
            if t.hasPrefix("complete task ")  { payload = String(t.dropFirst("complete task ".count)) }
            else if t.hasPrefix("finish task ") { payload = String(t.dropFirst("finish task ".count)) }
            else                               { payload = String(t.dropFirst("done with ".count)) }
            if !payload.isEmpty { return .completeTask(text: payload) }
        }
        if t == "overdue tasks" || t.contains("what is overdue") || t.contains("late tasks")
            || t.contains("what tasks are overdue") {
            return .overdueTasks
        }

        // System Settings — pane-aware extraction must come BEFORE generic "open"
        if t == "open settings" || t == "open system settings" || t == "system settings"
            || t == "open preferences" || t == "system preferences" || t == "settings" {
            return .openSystemSettings(pane: nil)
        }
        if let pane = extractSettingsPane(from: t) {
            return .openSystemSettings(pane: pane)
        }

        // Volume — "set volume to 50" / "set volume to 50%"
        if t.contains("set volume to") {
            let digits = t.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .joined()
            if let level = Int(digits), !digits.isEmpty {
                return .setVolume(level: level)
            }
        }

        // File operations
        if t == "open downloads" || t == "show downloads" || t == "go to downloads" {
            return .openFolder(name: "downloads")
        }
        if t == "open desktop folder" || t == "show desktop folder" { return .openFolder(name: "desktop") }
        if t == "open documents" || t == "show documents" || t == "go to documents" {
            return .openFolder(name: "documents")
        }
        if t == "open pictures" || t == "open photos folder" { return .openFolder(name: "pictures") }
        if t == "open movies" || t == "open videos" { return .openFolder(name: "movies") }
        if t == "open home folder" || t == "go home" || t == "go to home folder" {
            return .openFolder(name: "home")
        }
        if let folderName = match(t, prefix: "open folder ") {
            return .openFolder(name: folderName)
        }
        if t.hasPrefix("find file ") || t.hasPrefix("find my ") {
            let q: String
            if t.hasPrefix("find file ") { q = String(t.dropFirst("find file ".count)) }
            else { q = String(t.dropFirst("find my ".count)) }
            if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                return .findFile(query: q.trimmingCharacters(in: .whitespaces))
            }
        }
        if t.hasPrefix("search for ") && !t.contains("news") && !t.contains("memory") {
            let q = String(t.dropFirst("search for ".count)).trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { return .findFile(query: q) }
        }
        if t == "open latest download" || t == "latest download" || t == "open last download" {
            return .openLatestDownload
        }

        // App management — quit / hide / switch
        if let name = match(t, prefix: "quit "), !name.isEmpty {
            return .quitApp(name: name.capitalized)
        }
        if let name = match(t, prefix: "force quit "), !name.isEmpty {
            return .quitApp(name: name.capitalized)
        }
        if let name = match(t, prefix: "hide "),
           !["that", "this", "overlay", "news", "camera", "debug", "hud", "dashboard"].contains(name) {
            return .hideApp(name: name.capitalized)
        }
        if let name = match(t, prefix: "switch to "),
           !["next", "previous", "last", "another"].contains(name) {
            return .activateApp(name: name.capitalized)
        }
        if let name = match(t, prefix: "focus "),
           !["mode", "window"].contains(name) {
            return .activateApp(name: name.capitalized)
        }

        // Window / desktop controls
        if t == "show desktop" || t == "show the desktop" || t == "hide all windows" {
            return .showDesktop
        }
        if t == "lock screen" || t == "lock my screen" || t == "lock the screen"
            || t == "lock the mac" || t == "lock computer" {
            return .lockScreen
        }
        if t == "sleep display" || t == "sleep the display" || t == "turn off the screen"
            || t == "turn off display" {
            return .sleepDisplay
        }

        // Wi-Fi / Bluetooth toggles
        if t.contains("wifi") || t.contains("wi-fi") || t.contains("wireless") {
            if t.contains("off") || t.contains("disable") { return .wifiOff }
            if t.contains("on") || t.contains("enable")   { return .wifiOn }
            // "toggle wifi" — fall through to LLM which can query current state
        }
        if t.contains("bluetooth") || t.contains("blue tooth") {
            if t.contains("off") || t.contains("disable") { return .bluetoothOff }
            if t.contains("on") || t.contains("enable")   { return .bluetoothOn }
            // "toggle bluetooth" — fall through to LLM which can query current state
        }

        // App open shortcuts (kept last so system-specific commands win above)
        //
        // Phone-qualifier suffixes: strip them first so the app name is clean.
        //   "open spotify on my phone"  → phone
        //   "open spotify on my android" → phone
        //   "open spotify on my mac"    → mac  (default anyway)
        //   "open spotify"              → mac  (default)
        let phoneQualifiers  = [" on my phone", " on my android", " on phone",
                                " on android", " on the phone"]
        let macQualifiers    = [" on my mac", " on mac", " on my computer",
                                " on my laptop", " on here"]

        func appIntent(_ rawName: String, forcePhone: Bool) -> Intent {
            let lower = rawName.lowercased()
            if forcePhone || phoneOnlyApps.contains(lower) {
                return .openAppOnPhone(name: rawName.capitalized)
            }
            return .openApp(name: rawName.capitalized)
        }

        // Check phone qualifiers
        for q in phoneQualifiers {
            if t.hasSuffix(q) {
                let stripped = String(t.dropLast(q.count))
                for app in commonApps where stripped.contains("open \(app.lowercased())") {
                    return .openAppOnPhone(name: app)
                }
                if let name = match(stripped, prefix: "open ") {
                    return .openAppOnPhone(name: name.capitalized)
                }
                if let name = match(stripped, prefix: "launch ") {
                    return .openAppOnPhone(name: name.capitalized)
                }
            }
        }

        // Strip mac qualifiers (they don't change routing but clean up the name)
        var tForApp = t
        for q in macQualifiers where t.hasSuffix(q) {
            tForApp = String(t.dropLast(q.count))
            break
        }

        for app in commonApps where tForApp.contains("open \(app.lowercased())") {
            return appIntent(app, forcePhone: false)
        }
        if let name = match(tForApp, prefix: "open ") {
            let lower = name.lowercased()
            let folderNames = ["downloads", "desktop", "documents", "pictures", "photos",
                               "movies", "music", "home", "applications", "utilities"]
            if folderNames.contains(lower) { return .openFolder(name: lower) }
            return appIntent(name, forcePhone: false)
        }
        if let name = match(tForApp, prefix: "launch ") {
            return appIntent(name, forcePhone: false)
        }
        if let name = match(tForApp, prefix: "start ") {
            let lower = name.lowercased()
            if lower != "listening" { return appIntent(name, forcePhone: false) }
        }

        // Weather
        if t == "weather" || t == "what's the weather" || t == "whats the weather"
            || t == "how's the weather" || t == "hows the weather"
            || t == "weather today" || t == "current weather"
            || t == "what is the weather" || t == "what is the weather like"
            || t == "how hot is it" || t == "how cold is it"
            || t == "what's the temperature" || t == "whats the temperature"
            || t == "what's it like outside" || t == "whats it like outside"
            || t.contains("what's the weather") || t.contains("whats the weather")
            || t.contains("current weather") || t.contains("weather right now")
            || t.contains("weather outside") {
            return .currentWeather
        }
        if t.contains("forecast") || t.contains("weather this week")
            || t.contains("weather tomorrow") || t.contains("weather for the week")
            || t.contains("weekly forecast") || t.contains("week forecast")
            || t == "what's the forecast" || t == "whats the forecast" {
            if t.contains("tomorrow") { return .weatherForecast(days: 2) }
            if t.contains("week") || t.contains("5 day") || t.contains("five day") { return .weatherForecast(days: 5) }
            return .weatherForecast(days: 3)
        }
        if t == "will it rain" || t.contains("will it rain") || t.contains("going to rain")
            || t.contains("need an umbrella") || t.contains("need umbrella")
            || t.contains("bring an umbrella") || t == "is it going to rain today"
            || t == "is it going to rain tomorrow" {
            return .currentWeather  // weatherService handles rain queries
        }

        // Help / capabilities
        if t == "help" || t == "what can you do" || t == "what can you help with"
            || t == "what are your capabilities" || t == "what commands do you know"
            || t == "what do you know" || t == "how can you help"
            || t == "show me what you can do" || t == "list commands"
            || t == "what are your commands" || t.contains("what can you do")
            || t.contains("what are your capabilities") {
            return .jarvisHelp
        }

        // MARK: - Reddit
        //
        // The phrase store catches the canonical openers ("show reddit",
        // "open reddit", "summarise this post", etc.).  Everything below
        // handles the parametric variants the matcher can't enumerate:
        //   • "what are people saying about <topic>"  → redditQuery
        //   • "search reddit for <topic>"             → redditQuery
        //   • "show r/<name>" / "open <name>"         → showSubreddit
        //   • "open the second one" / "open the third post" → redditOpenIndex
        // Anything that doesn't shape-match falls through to the rest of
        // the router unchanged.

        // Parametric query: "what are people saying about X"
        for opener in [
            "what are people saying about ",
            "what is reddit saying about ",
            "what does reddit think about ",
            "what does reddit say about ",
            "reddit opinion on ",
            "reddit thoughts on ",
            "search reddit for ",
            "search my reddits for ",
        ] {
            if t.hasPrefix(opener) {
                let q = String(t.dropFirst(opener.count))
                    .trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { return .redditQuery(query: q) }
            }
        }

        // "show top reddits" — phrase store already covers this but the
        // substring fallback keeps it robust to filler.
        if t.contains("top reddit") || t == "what is hot on reddit"
            || t == "what is trending on reddit" {
            return .showRedditTop
        }

        // "open the Nth post" / "open the Nth reddit post" — gated on
        // the word "post" or "reddit" so the generic "open the second
        // one" doesn't get hijacked from other overlays.  JarvisController
        // resolves the index against the current Reddit context.
        if (t.contains("post") || t.contains("reddit"))
            && (t.hasPrefix("open ") || t.hasPrefix("show ")) {
            if let idx = extractOrdinalRedditIndex(in: t) {
                return .redditOpenIndex(index: idx)
            }
        }

        // Explicit subreddit openers: "show r technology", "show r/technology"
        // (the phrase normaliser drops slashes, so "r/technology" arrives
        // as "r technology" by the time we see it).
        for opener in [
            "show r ", "show the r ", "open r ",
            "show subreddit ", "open subreddit ",
            "show me subreddit ", "open the subreddit ",
            "show reddit r ",
        ] {
            if t.hasPrefix(opener) {
                let name = String(t.dropFirst(opener.count))
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " subreddit", with: "")
                if !name.isEmpty { return .showSubreddit(name: name) }
            }
        }

        // Last-mile natural shape: "show <name> subreddit", "open <name> reddit"
        if t.hasSuffix(" subreddit") || t.hasSuffix(" reddit") {
            var name = t
            for suffix in [" subreddit", " reddit"] {
                if name.hasSuffix(suffix) {
                    name = String(name.dropLast(suffix.count))
                }
            }
            for prefix in ["show ", "open ", "show me ", "open the "] {
                if name.hasPrefix(prefix) {
                    name = String(name.dropFirst(prefix.count))
                }
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed != "the" {
                return .showSubreddit(name: trimmed)
            }
        }

        // Shopify
        if t.contains("shopify")
            || (t.contains("order") && (t.contains("new") || t.contains("any") || t.contains("my")
                || t.contains("how many") || t.contains("total") || t.contains("today")))
            || t.contains("my orders") || t.contains("orders today") || t.contains("today's orders")
            || t.contains("todays orders") || t.contains("total orders")
            || t.contains("how many orders") || t.contains("orders do i have")
            || t.contains("today's revenue") || t.contains("todays revenue")
            || t.contains("what's my revenue") || t.contains("whats my revenue")
            || t.contains("how much have i made") || t.contains("how much did i make")
            || t.contains("how much money") || t.contains("revenue today")
            || t.contains("fulfilment queue") || t.contains("fulfillment queue")
            || t.contains("what needs fulfilling") || t.contains("what needs fulfillment")
            || t.contains("orders to fulfil") {
            if t.contains("show") || t.contains("open") || t.contains("dashboard") || t.contains("overlay") {
                return .showShopifyOverlay
            }
            if t.contains("fulfil") || t.contains("fulfill") || t.contains("shipping") {
                return .shopifyFulfilment
            }
            if t.contains("revenue") || t.contains("sales") || t.contains("money") || t.contains("how much") {
                return .shopifyRevenue
            }
            return .shopifyOrders
        }

        // Obsidian vault
        if t.contains("obsidian") || t.contains("my vault") || t.contains("my notes")
            || t.hasPrefix("what do i know") || t.hasPrefix("what have i written")
            || t.hasPrefix("create a note") || t.hasPrefix("new note")
            || t.hasPrefix("make a note") || t.hasPrefix("add to my note")
            || t.hasPrefix("append to") || t.hasPrefix("read my note")
            || t.hasPrefix("open my note") || t.hasPrefix("find in my notes") {

            // "what do i know about X" / "what have I written about X"
            if t.hasPrefix("what do i know about") {
                let topic = String(t.dropFirst("what do i know about".count)).trimmingCharacters(in: .whitespaces)
                return .whatDoIKnowAbout(topic: topic.isEmpty ? t : topic)
            }
            if t.hasPrefix("what have i written about") {
                let topic = String(t.dropFirst("what have i written about".count)).trimmingCharacters(in: .whitespaces)
                return .whatDoIKnowAbout(topic: topic.isEmpty ? t : topic)
            }
            if t.hasPrefix("check my notes for") {
                let topic = String(t.dropFirst("check my notes for".count)).trimmingCharacters(in: .whitespaces)
                return .whatDoIKnowAbout(topic: topic.isEmpty ? t : topic)
            }
            if t.hasPrefix("what's in my notes about") || t.hasPrefix("whats in my notes about") {
                let topic = t.components(separatedBy: " about ").dropFirst().joined(separator: " about ")
                return .whatDoIKnowAbout(topic: topic.isEmpty ? t : topic)
            }

            // Create note
            if t.hasPrefix("create a note") || t.hasPrefix("new note") || t.hasPrefix("make a note") || t.hasPrefix("create note") {
                // "create a note called X: Y" or "create a note called X"
                let rest = t
                    .replacingOccurrences(of: "create a note called ", with: "")
                    .replacingOccurrences(of: "create a note ", with: "")
                    .replacingOccurrences(of: "new note ", with: "")
                    .replacingOccurrences(of: "make a note ", with: "")
                    .replacingOccurrences(of: "create note ", with: "")
                let parts = rest.components(separatedBy: ": ")
                let title   = parts.first?.trimmingCharacters(in: .whitespaces) ?? rest
                let content = parts.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                return .createObsidianNote(title: title, content: content)
            }

            // Append to note
            if t.hasPrefix("add to my note") || t.hasPrefix("append to my note")
                || t.hasPrefix("update my note") || t.hasPrefix("add to my notes on") {
                // "add to my note about X: text" or "add to my X note: text"
                let rest = t
                    .replacingOccurrences(of: "add to my note about ", with: "")
                    .replacingOccurrences(of: "add to my note ", with: "")
                    .replacingOccurrences(of: "append to my note ", with: "")
                    .replacingOccurrences(of: "update my note ", with: "")
                    .replacingOccurrences(of: "add to my notes on ", with: "")
                let parts   = rest.components(separatedBy: ": ")
                let noteRef = parts.first?.trimmingCharacters(in: .whitespaces) ?? rest
                let text    = parts.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                return .appendToObsidianNote(title: noteRef, content: text)
            }

            // Read note aloud
            if t.hasPrefix("read my note about") || t.hasPrefix("read note") || t.hasPrefix("read my notes on") {
                let q = t
                    .replacingOccurrences(of: "read my note about ", with: "")
                    .replacingOccurrences(of: "read note ", with: "")
                    .replacingOccurrences(of: "read my notes on ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return .readObsidianNote(query: q.isEmpty ? t : q)
            }

            // Open / show a specific note
            if t.hasPrefix("open my note") || t.hasPrefix("open note")
                || t.hasPrefix("show my note") || t.hasPrefix("show note") {
                let q = t
                    .replacingOccurrences(of: "open my note about ", with: "")
                    .replacingOccurrences(of: "open my note ", with: "")
                    .replacingOccurrences(of: "open note ", with: "")
                    .replacingOccurrences(of: "show my note about ", with: "")
                    .replacingOccurrences(of: "show my note ", with: "")
                    .replacingOccurrences(of: "show note ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return .openObsidianNote(query: q.isEmpty ? t : q)
            }

            // Recent notes
            if t.contains("recent") || t == "my notes" || t == "my vault" { return .recentObsidianNotes }

            // Show/open overlay
            if t.contains("show") || t.contains("open") || t.contains("overlay") || t.contains("obsidian") {
                return .showObsidianOverlay
            }

            // Generic search fallback
            let q = t
                .replacingOccurrences(of: "search obsidian ", with: "")
                .replacingOccurrences(of: "search my vault ", with: "")
                .replacingOccurrences(of: "search my notes ", with: "")
                .replacingOccurrences(of: "find in obsidian ", with: "")
                .replacingOccurrences(of: "find my notes about ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .searchObsidian(query: q.isEmpty ? t : q)
        }

        // Apple Notes
        if t.contains("apple notes") || t.contains("open notes") || t.contains("show notes")
            || t.contains("notes app") {
            return .openNotes
        }
        if t.hasPrefix("create") && t.contains("note") || t.hasPrefix("new note")
            || t.hasPrefix("add a note") || t.hasPrefix("save a note")
            || t.hasPrefix("make a note") || t.hasPrefix("note that")
            || t.hasPrefix("take a note") {
            let body = t.replacingOccurrences(of: "create a note", with: "")
                        .replacingOccurrences(of: "create note", with: "")
                        .replacingOccurrences(of: "new note", with: "")
                        .replacingOccurrences(of: "add a note", with: "")
                        .replacingOccurrences(of: "save a note", with: "")
                        .replacingOccurrences(of: "make a note", with: "")
                        .replacingOccurrences(of: "note that", with: "")
                        .replacingOccurrences(of: "take a note", with: "")
                        .trimmingCharacters(in: .whitespaces)
            return .createNote(title: "", body: body)
        }
        if t.hasPrefix("append to") && t.contains("note") || t.hasPrefix("add to") && t.contains("note")
            || t.hasPrefix("update note") {
            let rest = t.replacingOccurrences(of: "append to note", with: "")
                        .replacingOccurrences(of: "add to note", with: "")
                        .replacingOccurrences(of: "add to my note", with: "")
                        .replacingOccurrences(of: "append to my note", with: "")
                        .replacingOccurrences(of: "update note", with: "")
                        .trimmingCharacters(in: .whitespaces)
            return .appendNote(title: rest, body: "")
        }
        if t.hasPrefix("search notes") || t.hasPrefix("search my notes")
            || t.hasPrefix("find note") || t.hasPrefix("find in notes")
            || t.hasPrefix("look up notes") {
            let query = t.replacingOccurrences(of: "search my notes", with: "")
                         .replacingOccurrences(of: "search notes", with: "")
                         .replacingOccurrences(of: "find note", with: "")
                         .replacingOccurrences(of: "find in notes", with: "")
                         .replacingOccurrences(of: "look up notes", with: "")
                         .trimmingCharacters(in: .whitespaces)
            return .searchNotes(query: query)
        }

        // Email / Apple Mail
        if t.contains("apple mail") || t == "open email" || t == "show email"
            || t == "mail app" || t == "open apple mail" || t == "show apple mail" {
            return .showEmail
        }
        if t.hasPrefix("check email") || t.hasPrefix("check my email")
            || t == "emails" || t == "new emails" || t == "any new emails" || t == "inbox" {
            return .checkEmail
        }
        if t == "unread emails" || t == "read unread" || t.hasPrefix("what emails")
            || t.hasPrefix("what's in my inbox") || t.hasPrefix("whats in my inbox") {
            return .unreadEmail
        }
        if t == "read latest email" || t == "latest email" || t == "most recent email"
            || t == "last email" || t == "read my email" {
            return .readLatestEmail
        }
        if t.hasPrefix("search email") || t.hasPrefix("search emails")
            || t.hasPrefix("search my email") || t.hasPrefix("find email")
            || t.hasPrefix("find emails") || t.hasPrefix("emails from")
            || t.hasPrefix("emails about") {
            let query = t.replacingOccurrences(of: "search my email", with: "")
                         .replacingOccurrences(of: "search emails", with: "")
                         .replacingOccurrences(of: "search email", with: "")
                         .replacingOccurrences(of: "find emails", with: "")
                         .replacingOccurrences(of: "find email", with: "")
                         .replacingOccurrences(of: "emails from", with: "")
                         .replacingOccurrences(of: "emails about", with: "")
                         .trimmingCharacters(in: .whitespaces)
            return .searchEmail(query: query)
        }
        if t == "summarise emails" || t == "summarize emails" || t == "email summary"
            || t == "email digest" || t.hasPrefix("what emails are unread") {
            return .summariseEmail
        }
        if t.hasPrefix("draft") && t.contains("email") || t.hasPrefix("compose")
            || t.hasPrefix("write an email") || t.hasPrefix("write email")
            || t.hasPrefix("new email") || t.hasPrefix("email to ") {
            let rest = t.replacingOccurrences(of: "draft an email to ", with: "")
                        .replacingOccurrences(of: "draft email to ", with: "")
                        .replacingOccurrences(of: "compose an email to ", with: "")
                        .replacingOccurrences(of: "compose email to ", with: "")
                        .replacingOccurrences(of: "write an email to ", with: "")
                        .replacingOccurrences(of: "write email to ", with: "")
                        .replacingOccurrences(of: "new email to ", with: "")
                        .replacingOccurrences(of: "email to ", with: "")
                        .trimmingCharacters(in: .whitespaces)
            return .draftEmail(to: rest, subject: "", body: "")
        }
        if t.hasPrefix("reply to") || t.hasPrefix("reply email") || t.hasPrefix("send reply") {
            let rest = t.replacingOccurrences(of: "reply to email ", with: "")
                        .replacingOccurrences(of: "reply to ", with: "")
                        .replacingOccurrences(of: "reply email ", with: "")
                        .replacingOccurrences(of: "send reply to ", with: "")
                        .trimmingCharacters(in: .whitespaces)
            return .replyEmail(to: rest, body: "")
        }
        if t == "important emails" || t == "urgent emails" || t == "priority emails"
            || t == "any urgent emails" || t == "vip emails" {
            return .importantEmail
        }

        // GitHub Intelligence — richer routing
        if t.contains("github") || t.contains("pull request") || t.contains(" pr ")
            || t.hasSuffix(" pr") || t.contains("open prs") || t.contains("check prs") {

            let repo = GitHubVoiceIntentRouter.extractRepo(t)

            // Dashboard
            if t.contains("dashboard") || t.contains("panel") {
                return .githubDashboard
            }
            // PRs
            if t.contains("review") && (t.contains("pr") || t.contains("pull")) {
                return .githubReviewPR(repo: repo, number: GitHubVoiceIntentRouter.extractNumber(t))
            }
            if t.contains("open pr") || t.contains("create pr") || t.contains("create a pr") {
                return .githubOpenPR(repo: repo)
            }
            if t.contains("stale pr") || t.contains("old pr") { return .githubStalePRs(repo: repo) }
            if t.contains("pr") || t.contains("pull request") { return .githubListPRs(repo: repo) }
            // Issues
            if t.contains("create issue") || t.contains("open issue") || t.contains("file issue") {
                return .githubCreateIssue(repo: repo, title: GitHubVoiceIntentRouter.extractQuotedText(t))
            }
            if t.contains("stale issue") { return .githubStaleIssues(repo: repo) }
            if t.contains("issue") { return .githubListIssues(repo: repo) }
            // CI
            if t.contains("ci") || t.contains("build") || t.contains("failing") {
                return .githubCheckCI(repo: repo)
            }
            // Repos
            if t.contains("create repo") || t.contains("new repo") || t.contains("create repository") {
                return .githubCreateRepo(name: GitHubVoiceIntentRouter.extractRepoName(t))
            }
            if t.contains("my repos") || t.contains("list repos") { return .githubListMyRepos }
            if t.contains("neglect") || t.contains("stale repo") { return .githubNeglectedRepos }
            if t.contains("active repo") { return .githubActiveRepos }
            // Roadmap
            if t.contains("project status") || t.contains("roadmap") || t.contains("how far")
                || t.contains("what's left") || t.contains("blocking") {
                return .githubProjectStatus(repo: repo)
            }
            // Code review
            if t.contains("code review") || t.contains("review code") || t.contains("risky") {
                return .githubCodeReview(repo: repo)
            }
            // Commits
            if t.contains("commit") || t.contains("recent change") {
                return .githubRecentCommits(repo: repo)
            }
            return .checkGitHub
        }
        if t.contains("new review") || t.contains("any review") { return .checkGitHub }
        if t.contains("create a repo") || t.contains("new repository") || t.contains("start a project") {
            return .githubCreateRepo(name: GitHubVoiceIntentRouter.extractRepoName(t))
        }
        if t.contains("project status") || t.contains("how far are we") {
            return .githubProjectStatus(repo: GitHubVoiceIntentRouter.extractRepo(t))
        }

        // Daily briefing
        if t == "what did i miss" || t == "daily briefing" || t == "morning briefing"
            || t == "give me a summary" || t == "brief me" || t == "catch me up"
            || t == "what's new" || t == "whats new" || t == "what happened"
            || t.contains("what did i miss") || t.contains("daily briefing")
            || t.contains("morning briefing") || t.contains("catch me up")
            || t == "give me the rundown" || t == "what's going on today"
            || t == "whats going on today" || t == "rundown" || t == "briefing" {
            return .dailyBriefing
        }

        // MARK: Timers
        let timerTriggers = ["set a timer", "set timer", "start a timer", "timer for",
                             "timer in", "set me a timer", "create a timer"]
        if timerTriggers.contains(where: { t.hasPrefix($0) || t.contains($0) }) {
            let secs = parseTimeDuration(from: t)
            let name = parseTimerName(from: t)
            return .setTimer(seconds: secs, name: name)
        }
        if t.contains("cancel") && t.contains("timer") {
            if t.contains("all") { return .cancelAllTimers }
            let name = t
                .replacingOccurrences(of: "cancel", with: "")
                .replacingOccurrences(of: "timer", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .cancelTimer(name: name.isEmpty ? nil : name)
        }
        if (t.contains("how long") && t.contains("timer")) || t == "timer status"
            || t == "time left" || t.contains("time remaining")
            || t.contains("how much time") || t.contains("how long on the timer") {
            return .timerStatus
        }

        // Stopwatch
        if t.contains("stopwatch") || (t.contains("start") && t.contains("clock")) {
            if t.contains("stop") || t.contains("pause") { return .stopStopwatch }
            if t.contains("how long") || t.contains("elapsed") || t.contains("status") {
                return .stopwatchStatus
            }
            return .startStopwatch
        }

        // Clipboard
        if t.contains("clipboard") || t.contains("what's in my clip")
            || t.contains("what did i copy") {
            return .clipboardRead
        }
        if t.contains("copy") && (t.contains("that") || t.contains("last response")
            || t.contains("what you said")) {
            return .clipboardCopy
        }

        // Spotify / Music — matched last so specific phrases above win first.
        // Pause / stop checked before play so "stop music" doesn't route to .spotifyPlay.
        if t == "pause" || t == "pause music" || t == "stop music"
            || t == "stop the music" || t == "stop playing" || t == "stop spotify" {
            return .spotifyPause
        }
        if t == "resume" || t == "resume music" || t == "unpause"
            || t == "unpause music" || t == "continue playing" || t == "continue music" {
            return .spotifyResume
        }
        if t == "next song" || t == "skip song" || t == "skip track"
            || t == "next track" || t == "skip this" {
            return .spotifyNext
        }
        if t == "previous song" || t == "previous track" || t == "last song"
            || t == "back track" {
            return .spotifyPrevious
        }
        if t == "what's playing" || t == "whats playing" || t == "what is playing"
            || t == "what song is this" || t == "current song" || t == "current track"
            || t == "what are you playing" {
            return .spotifyWhatIsPlaying
        }
        if t.contains("shuffle on") || t == "turn on shuffle" || t == "enable shuffle" {
            return .spotifyShuffle(on: true)
        }
        if t.contains("shuffle off") || t == "turn off shuffle" || t == "disable shuffle" {
            return .spotifyShuffle(on: false)
        }
        if t.contains("spotify") || t.contains("play music") || t.contains("play some music") {
            if t.contains("pause") || t.contains("stop") { return .spotifyPause }
            if t.contains("resume") || t.contains("unpause") || t.contains("continue") {
                return .spotifyResume
            }
            if t.contains("next") || t.contains("skip") { return .spotifyNext }
            if t.contains("previous") || t.contains("go back") { return .spotifyPrevious }
            if t.contains("what") && (t.contains("playing") || t.contains("song") || t.contains("track")) {
                return .spotifyWhatIsPlaying
            }
            if t.contains("shuffle") {
                return .spotifyShuffle(on: !t.contains("off"))
            }
            if t.contains("volume") {
                let nums = t.components(separatedBy: .whitespaces).compactMap { Int($0) }
                return .spotifyVolume(percent: nums.first ?? 50)
            }
            return .spotifyPlay(query: nil)
        }
        if t.hasPrefix("play ") {
            let query = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // Exclude "play news" which is already handled above
            let blocklist: Set<String> = ["news", "the news", "live news"]
            if !query.isEmpty && !blocklist.contains(query) {
                return .spotifyPlay(query: query)
            }
        }

        // MARK: - Android Bridge / Mobile

        // Show overlay / status
        if t.contains("android") || t.contains("phone status") || t.contains("bridge status") {
            if t.contains("show") || t.contains("open") || t.contains("overlay")
                || t.contains("panel") || t.contains("dashboard") {
                return .showAndroidOverlay
            }
            return .androidBridgeStatus
        }

        // Ring / find phone
        if t == "ring my phone" || t == "ring phone" || t.contains("make my phone ring")
            || t == "find my phone" || t.contains("where is my phone")
            || t.contains("make it ring") || t == "ring it" {
            if t.contains("find") || t.contains("where") { return .phoneLocation }
            return .ringPhone
        }
        if t.contains("phone location") || t.contains("locate my phone")
            || t.contains("track my phone") {
            return .phoneLocation
        }

        // ── Phase-1 remote call control ───────────────────────────────────────
        // These are placed BEFORE general "call" routing to avoid misfire.
        if t == "answer it" || t == "answer the call" || t == "pick up"
            || t == "pick it up" || t == "accept the call" || t == "accept it"
            || t == "answer phone" {
            return .answerCall
        }
        if t == "decline it" || t == "decline the call" || t == "reject it"
            || t == "reject the call" || t == "ignore it" || t == "ignore the call"
            || t == "send to voicemail" || t == "don't answer" {
            return .declineCall
        }
        if t == "hang up" || t == "end the call" || t == "hang up the call"
            || t == "end call" || t == "hang up now" {
            return .hangUpCall
        }
        if t == "speaker on" || t == "speakerphone on" || t == "put it on speaker"
            || t == "turn on speaker" || t == "put on speakerphone" || t == "switch to speaker"
            || t.hasPrefix("put it on speaker") {
            return .speakerOn
        }
        if t == "speaker off" || t == "speakerphone off" || t == "turn speaker off"
            || t == "turn off speaker" || t == "take off speakerphone" || t == "switch off speaker" {
            return .speakerOff
        }

        // ── Android phone event follow-up actions ─────────────────────────────
        // "Call back" — before general "call" routing to avoid false match
        if t == "call back" || t == "call him back" || t == "call her back"
            || t == "call them back" || t == "return the call"
            || t == "ring them back" || t == "ring him back" || t == "ring her back"
            || t == "phone them back" || t == "call that person back" {
            return .callBackLastCaller
        }

        // "Reply saying X" / "reply with X" — extract message body
        for prefix in ["reply saying ", "reply with ", "send a reply saying ",
                       "send a reply with ", "message them back saying "] {
            if t.hasPrefix(prefix) {
                let msg = String(t.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return .replyToLastSender(message: msg)
            }
        }
        if t == "reply" || t == "reply to that" || t == "send a reply"
            || t == "message them back" || t == "reply to message" {
            return .replyToLastSender(message: "")
        }

        // "What did they say" — show latest message
        if t == "what did they say" || t == "what did she say" || t == "what did he say"
            || t == "what was the message" || t == "show the message"
            || t == "show me the message" || t == "show latest message"
            || t == "read the message" || t == "what did they text"
            || t == "what did they whatsapp" {
            return .showLatestAndroidMessage
        }

        // Call contact — must come before generic "call" to avoid early exit
        if t.hasPrefix("call ") {
            let name = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .callContact(name: name) }
        }
        if t.hasPrefix("ring ") || t.hasPrefix("dial ") || t.hasPrefix("phone ") {
            let name = t.components(separatedBy: " ").dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .callContact(name: name) }
        }
        if t.contains("call") && (t.contains("contact") || t.contains("them")
            || t.contains("him") || t.contains("her")) {
            let name = t
                .replacingOccurrences(of: "call", with: "")
                .replacingOccurrences(of: "contact", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .callContact(name: name) }
        }

        // WhatsApp
        if t.contains("whatsapp") || t.contains("whats app") {
            var recipient = ""
            var message = ""
            if let toRange = t.range(of: "to ") {
                let after = String(t[toRange.upperBound...])
                if let sayRange = after.range(of: " saying ") {
                    recipient = String(after[..<sayRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    message = String(after[sayRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    recipient = after.trimmingCharacters(in: .whitespaces)
                }
            }
            return .sendWhatsApp(recipient: recipient, message: message)
        }

        // SMS / text
        if t.hasPrefix("text ") || t.hasPrefix("send a text") || t.hasPrefix("send text")
            || t.hasPrefix("send an sms") || t.hasPrefix("send sms")
            || (t.contains("text") && t.contains("saying"))
            || (t.contains("sms") && t.contains("to")) {
            var recipient = ""
            var message = ""
            // "text John saying hello"
            if let toRange = t.range(of: "text ") {
                let after = String(t[toRange.upperBound...])
                if let sayRange = after.range(of: " saying ") {
                    recipient = String(after[..<sayRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    message = String(after[sayRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else if let toRange2 = after.range(of: " to ") {
                    // "send text to John saying hello"
                    recipient = String(after[toRange2.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    recipient = after.trimmingCharacters(in: .whitespaces)
                }
            }
            return .sendSMS(recipient: recipient, message: message)
        }

        // Contact search
        if (t.hasPrefix("find contact") || t.hasPrefix("search contacts")
            || t.hasPrefix("look up contact") || t.contains("find contact named")) {
            let q = t
                .replacingOccurrences(of: "find contact named ", with: "")
                .replacingOccurrences(of: "find contact ", with: "")
                .replacingOccurrences(of: "search contacts for ", with: "")
                .replacingOccurrences(of: "search contacts ", with: "")
                .replacingOccurrences(of: "look up contact ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .findContact(query: q)
        }

        // Navigation — also handles "navigate home", "take me home", bare "navigate"
        if t == "navigate" || t == "navigate home" || t == "take me home"
            || t == "go home" || t == "head home" || t == "drive home" {
            let dest = (t == "navigate") ? "" : "home"
            return .startNavigation(destination: dest)
        }
        if t.hasPrefix("navigate to ") || t.hasPrefix("directions to ")
            || t.hasPrefix("take me to ") || t.hasPrefix("get me to ")
            || t.hasPrefix("how do i get to ") || t.hasPrefix("navigate ") {
            let dest = t
                .replacingOccurrences(of: "navigate to ", with: "")
                .replacingOccurrences(of: "navigate ", with: "")
                .replacingOccurrences(of: "directions to ", with: "")
                .replacingOccurrences(of: "take me to ", with: "")
                .replacingOccurrences(of: "get me to ", with: "")
                .replacingOccurrences(of: "how do i get to ", with: "")
                .trimmingCharacters(in: .whitespaces)
            // Always return — execute() will prompt for destination if empty
            return .startNavigation(destination: dest)
        }

        // Notifications
        if t == "read my notifications" || t == "read notifications"
            || t == "what are my notifications" || t == "show my notifications from my phone"
            || t == "check my phone notifications" || t == "what are my phone notifications"
            || t.contains("phone notification") || t == "latest notification"
            || t == "recent notifications" {
            return .readNotifications
        }
        if t.hasPrefix("notifications from ") || t.hasPrefix("notification from ") {
            let app = t
                .replacingOccurrences(of: "notifications from ", with: "")
                .replacingOccurrences(of: "notification from ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !app.isEmpty { return .queryNotification(app: app) }
        }

        // "what did Cath message me" / "what did Mike say" / "what did she send me"
        if t.hasPrefix("what did ") {
            let rest = String(t.dropFirst("what did ".count))
            let stripped = rest
                .replacingOccurrences(of: " message me", with: "")
                .replacingOccurrences(of: " say to me", with: "")
                .replacingOccurrences(of: " send me", with: "")
                .replacingOccurrences(of: " say", with: "")
                .replacingOccurrences(of: " write me", with: "")
                .replacingOccurrences(of: " write", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty && stripped != "i" && stripped != "you" {
                return .queryNotification(app: stripped)
            }
        }

        // "did I reply to Mike" / "have I replied to Cath"
        if t.hasPrefix("did i reply to ") || t.hasPrefix("have i replied to ")
            || t.hasPrefix("did i respond to ") {
            let name = t
                .replacingOccurrences(of: "did i reply to ", with: "")
                .replacingOccurrences(of: "have i replied to ", with: "")
                .replacingOccurrences(of: "did i respond to ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .queryNotification(app: name) }
        }

        // "any messages from X" / "messages from X" / "message from X"
        if t.contains(" messages from ") || t.contains(" message from ") {
            for prefix in ["any messages from ", "any message from ", "messages from ", "message from "] {
                if let range = t.range(of: prefix) {
                    let name = String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return .queryNotification(app: name) }
                }
            }
        }

        // Phone camera
        if t.contains("phone camera") || t.contains("camera on my phone")
            || t.contains("capture from phone") || t.contains("take photo on phone") {
            return .capturePhoneCamera
        }

        // Spatial Interaction — widget nudging (Sprint M)
        if t.contains("move that left") || t.contains("move this left") || t.contains("move it left") { return .moveWidgetLeft }
        if t.contains("move that right") || t.contains("move this right") || t.contains("move it right") { return .moveWidgetRight }
        if t.contains("move that up") || t.contains("move this up") || t.contains("move it up") { return .moveWidgetUp }
        if t.contains("move that down") || t.contains("move this down") || t.contains("move it down") { return .moveWidgetDown }
        if t.contains("make it bigger") || t.contains("make this bigger") || t.contains("make that bigger")
            || t.contains("expand that") || t.contains("expand this") { return .resizeWidgetLarge }
        if t.contains("make it smaller") || t.contains("make this smaller") || t.contains("make that smaller")
            || t.contains("shrink that") || t.contains("shrink this") { return .resizeWidgetSmall }
        if t.contains("minimize this") || t.contains("minimize that") || t.contains("minimize widget")
            || t.contains("collapse this") || t.contains("collapse that") { return .minimizeWidget }

        // Spatial Interaction — workspace management (Sprint M)
        if t.contains("save workspace") || t.contains("save this layout") || t.contains("save my layout") || t.contains("create workspace") {
            let name = t.replacingOccurrences(of: "save workspace", with: "").replacingOccurrences(of: "save this layout as", with: "").trimmingCharacters(in: .whitespaces)
            return .saveWorkspace(name: name.isEmpty ? "Workspace" : name.capitalized)
        }
        if t.contains("restore workspace") || t.contains("load workspace") || t.contains("open workspace") || t.contains("switch to workspace") {
            let name = t.replacingOccurrences(of: "restore workspace", with: "").replacingOccurrences(of: "load workspace", with: "").replacingOccurrences(of: "open workspace", with: "").trimmingCharacters(in: .whitespaces)
            return .restoreWorkspace(name: name.isEmpty ? "" : name.capitalized)
        }
        if t == "list workspaces" || t == "show workspaces" || t == "my workspaces" || t == "show my layouts" { return .listWorkspaces }

        // Spatial Interaction — window management (Sprint M)
        if t.contains("tile windows") || t.contains("tile all windows") || t.contains("arrange windows") { return .tileWindows }
        if t.contains("snap") && t.contains("left") && !t.contains("widget") {
            let app = t.replacingOccurrences(of: "snap", with: "").replacingOccurrences(of: "to the left", with: "").replacingOccurrences(of: "left", with: "").trimmingCharacters(in: .whitespaces)
            return .snapWindowLeft(appName: app)
        }
        if t.contains("snap") && t.contains("right") && !t.contains("widget") {
            let app = t.replacingOccurrences(of: "snap", with: "").replacingOccurrences(of: "to the right", with: "").replacingOccurrences(of: "right", with: "").trimmingCharacters(in: .whitespaces)
            return .snapWindowRight(appName: app)
        }
        if t.contains("focus on ") || t.contains("switch to ") || t.contains("bring up ") {
            let app = t.replacingOccurrences(of: "focus on", with: "").replacingOccurrences(of: "switch to", with: "").replacingOccurrences(of: "bring up", with: "").trimmingCharacters(in: .whitespaces)
            if !app.isEmpty && !["the overlay", "the panel", "the window", "the widget"].contains(app) {
                return .focusWindow(appName: app)
            }
        }

        // Spatial Interaction — docking/snapping (Sprint M)
        if (t.contains("dock this") || t.contains("dock that")) {
            let edge = t.contains("right") ? "right" : t.contains("top") ? "top" : t.contains("bottom") ? "bottom" : "left"
            return .dockWidget(edge: edge)
        }
        if t.hasPrefix("snap") && (t.contains("top") || t.contains("bottom") || t.contains("left") || t.contains("right") || t.contains("center")) {
            let zone: String
            if t.contains("top") && t.contains("left") { zone = "topLeft" }
            else if t.contains("top") && t.contains("right") { zone = "topRight" }
            else if t.contains("bottom") && t.contains("left") { zone = "bottomLeft" }
            else if t.contains("bottom") && t.contains("right") { zone = "bottomRight" }
            else if t.contains("top") { zone = "topHalf" }
            else if t.contains("bottom") { zone = "bottomHalf" }
            else if t.contains("left") { zone = "leftThird" }
            else if t.contains("right") { zone = "rightThird" }
            else { zone = "center" }
            return .snapWidget(zone: zone)
        }

        if t == "show spatial debug" || t == "spatial debug" || t == "spatial diagnostics" || t == "gesture debug" { return .showSpatialDebug }

        return .unknown(text)
    }

    // MARK: - helpers

    /// Extract a settings pane name from phrases like "open wifi settings",
    /// "show bluetooth settings", "open the display settings", etc.
    private func extractSettingsPane(from text: String) -> String? {
        let prefixes = ["open ", "show ", "go to "]
        let suffixes = [" settings", " setting", " preferences", " pane"]
        let paneKeywords = [
            "wifi", "wi-fi", "bluetooth", "sound", "audio", "display", "displays",
            "screen", "privacy", "security", "keyboard", "mouse", "trackpad",
            "notifications", "notification", "battery", "energy", "power", "network",
            "accessibility", "appearance", "focus", "siri", "language", "region",
            "date", "time", "sharing", "users", "accounts", "screensaver",
            "screen saver", "wallpaper", "desktop", "printers", "printing"
        ]
        var s = text
        for p in prefixes { if s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break } }
        // Strip "the " article
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        for suf in suffixes { if s.hasSuffix(suf) { s = String(s.dropLast(suf.count)); break } }
        s = s.trimmingCharacters(in: .whitespaces)
        return paneKeywords.contains(s) ? s : nil
    }

    private let commonApps = [
        "Safari", "Chrome", "Finder", "Terminal", "Mail", "Messages",
        "Calendar", "Notes", "Reminders", "Music", "Photos", "Preview",
        "Slack", "Spotify", "Visual Studio Code", "Xcode"
    ]

    /// Apps that only exist on Android / have no meaningful Mac counterpart.
    /// Saying "open WhatsApp" (no qualifier) auto-routes to the phone.
    private let phoneOnlyApps: Set<String> = [
        "whatsapp", "tiktok", "instagram", "snapchat", "signal",
        "telegram", "threads", "bereal", "capcut", "shazam",
        "google maps", "waze", "google pay", "google photos",
        "android auto", "google home"
    ]

    private func match(_ text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Shared NSDataDetector — expensive to construct; cached as static so it's
    /// only built once rather than on every transcript routed through the router.
    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Extract a WhatsApp-call intent from the normalised transcript.
    /// Returns nil if the phrase doesn't look like a WhatsApp call request.
    ///
    /// The classifier prefers explicit "on whatsapp" markers, then
    /// "whatsapp (video) call X" prefixes.  Contact name is everything
    /// between the verb and any " on whatsapp" suffix, with common
    /// articles ("the", "my") and the wake-word filler stripped at the
    /// edges.
    private func whatsAppCallIntent(in t: String) -> Intent? {
        // Trim trailing " on whatsapp" / " via whatsapp" / " over whatsapp"
        // and remember whether we found one — drives the "is this a
        // whatsapp call?" decision.
        let suffixMarkers = [" on whatsapp", " via whatsapp", " over whatsapp", " through whatsapp"]
        var stripped = t
        var hasWhatsAppSuffix = false
        for marker in suffixMarkers {
            if stripped.hasSuffix(marker) {
                stripped = String(stripped.dropLast(marker.count))
                hasWhatsAppSuffix = true
                break
            }
        }

        // Video call shape: "video call X on whatsapp" or "video whatsapp X".
        let videoVerbs = ["video call ", "video whatsapp ", "whatsapp video call ", "whatsapp video "]
        for verb in videoVerbs {
            if stripped.hasPrefix(verb) {
                let contact = cleanContact(String(stripped.dropFirst(verb.count)))
                guard !contact.isEmpty else { return nil }
                return .whatsAppVideoCall(contact: contact)
            }
        }
        if hasWhatsAppSuffix, stripped.hasPrefix("video call ") {
            let contact = cleanContact(String(stripped.dropFirst("video call ".count)))
            if !contact.isEmpty { return .whatsAppVideoCall(contact: contact) }
        }

        // Voice call shape — only if we've confirmed WhatsApp context
        // ("X on whatsapp" suffix or "whatsapp call X" prefix).  Without
        // an explicit WhatsApp marker, fall through to the generic
        // `.callContact` route the existing call/ring/dial/phone handlers
        // produce.
        let voiceVerbs = ["whatsapp call ", "whatsapp voice call "]
        for verb in voiceVerbs {
            if stripped.hasPrefix(verb) {
                let contact = cleanContact(String(stripped.dropFirst(verb.count)))
                guard !contact.isEmpty else { return nil }
                return .whatsAppVoiceCall(contact: contact)
            }
        }
        if hasWhatsAppSuffix {
            for verb in ["call ", "phone ", "ring ", "dial "] {
                if stripped.hasPrefix(verb) {
                    let contact = cleanContact(String(stripped.dropFirst(verb.count)))
                    guard !contact.isEmpty else { return nil }
                    return .whatsAppVoiceCall(contact: contact)
                }
            }
        }
        return nil
    }

    /// Strip leading articles + trailing punctuation so contact names land
    /// cleanly as `"Mike"` rather than `"the mike."`.
    private func cleanContact(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "my ", "a ", "an "] {
            if s.hasPrefix(article) { s = String(s.dropFirst(article.count)) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        return s.capitalized
    }

    private func firstURL(in text: String) -> URL? {
        guard let detector = Self.linkDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }

    private func resolveEntity(in phrase: String) -> String? {
        let clean = phrase
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: "my ", with: "")
        return homeEntityResolver?(clean)
    }

    /// Parse "dim/brighten/set brightness <entity> to <level>%"
    /// Returns (entityPhrase, level 0-100) or nil
    private func parseSetBrightness(_ t: String) -> (String, Int)? {
        // Patterns: "dim <entity> to <N>", "set brightness to <N>", "brighten <entity>"
        let patterns: [(prefix: String, extractEntity: Bool)] = [
            ("dim ", true),
            ("brighten ", true),
            ("set brightness to ", false),
            ("set the brightness to ", false),
        ]
        for (prefix, extractEntity) in patterns {
            guard t.hasPrefix(prefix) else { continue }
            let rest = String(t.dropFirst(prefix.count))
            // Extract number from "to <N>%" or just digits
            let level = extractPercentage(from: rest) ?? (t.contains("brighten") ? 80 : 30)
            if extractEntity {
                let entity = rest
                    .components(separatedBy: " to ").first?
                    .trimmingCharacters(in: .whitespaces) ?? rest
                if !entity.isEmpty { return (entity, level) }
            } else {
                return ("last", level)  // generic brightness change
            }
        }
        // "set <entity> to <N>%" — generic setter
        if t.hasPrefix("set ") && t.contains(" to ") && t.contains("%") {
            let parts = t.dropFirst("set ".count).components(separatedBy: " to ")
            if parts.count >= 2, let level = extractPercentage(from: parts[1]) {
                return (parts[0].trimmingCharacters(in: .whitespaces), level)
            }
        }
        return nil
    }

    /// Parse "make/set/change <entity> <color>"
    /// Returns (entityPhrase, colorName) or nil
    private func parseSetColor(_ t: String) -> (String, String)? {
        let colors = ["red", "orange", "yellow", "green", "cyan", "blue",
                      "purple", "pink", "white", "warm white", "cool white"]
        for color in colors {
            // "make it red", "make the bedroom red", "set bedroom to red"
            if t.hasSuffix(" \(color)") || t.hasSuffix(" to \(color)") {
                let withoutColor = t.hasSuffix(" to \(color)")
                    ? String(t.dropLast(" to \(color)".count))
                    : String(t.dropLast(" \(color)".count))
                // Strip leading verb
                let entity = withoutColor
                    .replacingOccurrences(of: "make it", with: "")
                    .replacingOccurrences(of: "make ", with: "")
                    .replacingOccurrences(of: "set ", with: "")
                    .replacingOccurrences(of: "change ", with: "")
                    .replacingOccurrences(of: "turn it", with: "")
                    .replacingOccurrences(of: "turn ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !entity.isEmpty { return (entity, color) }
                return ("last", color)
            }
        }
        return nil
    }

    /// Extract a cover entity name from phrases like "open the garage" etc.
    private func extractCoverEntity(from t: String, action: String) -> String {
        let strip = "\(action) the "
        let strip2 = "\(action) "
        if t.hasPrefix(strip) { return String(t.dropFirst(strip.count)) }
        if t.hasPrefix(strip2) { return String(t.dropFirst(strip2.count)) }
        return "cover"
    }

    /// Extract a number (0-100) from strings like "50%", "50 percent", "50"
    private func extractPercentage(from s: String) -> Int? {
        let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        return min(100, max(0, n))
    }

    /// Extract a duration in seconds from natural language like
    /// "5 minutes", "30 seconds", "1 hour 30 minutes", "1.5 hours".
    private func parseTimeDuration(from text: String) -> TimeInterval {
        let t = text.lowercased()
        var total: TimeInterval = 0

        // Hours
        if let range = t.range(of: #"(\d+(?:\.\d+)?)\s*hour"#, options: .regularExpression) {
            let s = String(t[range])
            let numStr = s.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")))
                          .filter { !$0.isEmpty }.first ?? "0"
            if let n = Double(numStr) { total += n * 3600 }
        }
        // Minutes
        if let range = t.range(of: #"(\d+(?:\.\d+)?)\s*min"#, options: .regularExpression) {
            let s = String(t[range])
            let numStr = s.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")))
                          .filter { !$0.isEmpty }.first ?? "0"
            if let n = Double(numStr) { total += n * 60 }
        }
        // Seconds
        if let range = t.range(of: #"(\d+(?:\.\d+)?)\s*sec"#, options: .regularExpression) {
            let s = String(t[range])
            let numStr = s.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")))
                          .filter { !$0.isEmpty }.first ?? "0"
            if let n = Double(numStr) { total += n }
        }
        // Bare number fallback — "set a 5 timer" → assume minutes
        if total == 0 {
            let nums = t.components(separatedBy: .whitespaces).compactMap { Double($0) }
            if let n = nums.first { total = n * 60 }
        }
        return max(total, 5) // minimum 5 seconds
    }

    /// Extract an optional timer name from phrases like
    /// "start a timer called pasta for 8 minutes".
    private func parseTimerName(from text: String) -> String? {
        let t = text.lowercased()
        if let range = t.range(of: "called ") {
            let after = String(t[range.upperBound...])
            let name = after.components(separatedBy: " for ").first?
                .components(separatedBy: " in ").first ?? after
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let range = t.range(of: "named ") {
            let after = String(t[range.upperBound...])
            let name = after.components(separatedBy: " for ").first ?? after
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Parse "open the second reddit post", "open the third one",
    /// "open first post", "show post 2".  Returns a **0-based** index so
    /// it can be applied straight to an array.  Nil if no clear ordinal
    /// is present.  Independent of `parseStoryOrdinal` because Reddit
    /// posts are 0-based and the routing copy uses "post" / "one"
    /// rather than "story" / "article".
    fileprivate func extractOrdinalRedditIndex(in text: String) -> Int? {
        var s = text
        let strip = ["open the ", "open ", "show the ", "show ",
                     "reddit ", "post ", " post", " one", "the "]
        for token in strip {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        let words: [String: Int] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4,
            "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
            "ninth": 9, "tenth": 10,
        ]
        for (word, n) in words where s.contains(word) {
            return n - 1
        }
        // Digit ordinals.
        let digits = s.split(whereSeparator: { !$0.isNumber }).first
        if let d = digits, let n = Int(d), n > 0 { return n - 1 }
        return nil
    }

    /// Parse phrases like "open story one", "open the first story",
    /// "show article 2", "open story number three". Returns the 1-based
    /// index, or nil if no clear ordinal is found.
    fileprivate func parseStoryOrdinal(in text: String,
                                       verbs: [String]) -> Int? {
        var s = text
        for v in verbs {
            if s.hasPrefix(v) { s = String(s.dropFirst(v.count)); break }
        }
        // Strip "the " and articles, "story", "article", "headline".
        s = s
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: "first story", with: "story 1")
            .replacingOccurrences(of: "first article", with: "article 1")
            .replacingOccurrences(of: "second story", with: "story 2")
            .replacingOccurrences(of: "second article", with: "article 2")
            .replacingOccurrences(of: "third story", with: "story 3")
            .replacingOccurrences(of: "third article", with: "article 3")
            .replacingOccurrences(of: "fourth story", with: "story 4")
            .replacingOccurrences(of: "fifth story", with: "story 5")
            .replacingOccurrences(of: "story number ", with: "story ")
            .replacingOccurrences(of: "article number ", with: "article ")

        let prefixes = ["story ", "article ", "headline ", "story", "article"]
        var num = ""
        for p in prefixes {
            if let r = s.range(of: p) {
                num = String(s[r.upperBound...])
                break
            }
        }
        num = num.trimmingCharacters(in: .whitespaces)
        // Number words
        let wordMap: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        if let n = wordMap[num] { return n }
        if let n = Int(num), n >= 1 { return n }
        return nil
    }
}
