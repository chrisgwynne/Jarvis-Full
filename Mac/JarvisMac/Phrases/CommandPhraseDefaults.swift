import Foundation

/// Built-in default phrase library seeded on first launch.
///
/// Phrases are stored as spoken/typed; `CommandPhrase.init` normalises
/// each one via `TranscriptNormalizer` so matching is always symmetric.
///
/// When adding phrases: write them as a user would naturally say them.
/// The normaliser will canonicalise both the stored phrase AND any
/// incoming transcript before comparison.
enum CommandPhraseDefaults {

    static var all: [CommandDefinition] {
        news + camera + ui + overlays + time + memory + screen + system + smallTalk + listening + identity
        + apps + systemSettings + volume + files + windows + proactivity
        + homeAssistant + haAutomations + calendar + calendarOverlay + todoist + tasksOverlay + weather + help + briefing
        + github + homeOverlay + haCameras + systemToggles + timers + clipboard
        + spotify + shopify + obsidian + mobile + reddit + appleNotes + email + conversational + surveillance + spatial
    }

    // MARK: - News

    static var news: [CommandDefinition] { [
        def("show_news", "Show News", .news, "Open the news headlines overlay.", .low, [
            // Core phrases
            ("show news",                       .exact),
            ("open news",                       .exact),
            ("news",                            .exact),
            // Natural variations (normaliser strips "me", "the", rewrites "show me" → "show")
            ("show me the news",                .exact),
            ("show me news",                    .exact),
            ("bring up the news",               .exact),
            ("pull up the news",                .exact),
            ("display news",                    .exact),
            // Question forms
            ("what is the news",                .exact),
            ("what is in the news",             .exact),
            ("what is happening",               .contains),
            ("what is happening today",         .exact),
            ("what is going on",                .exact),
            ("what are the headlines",          .exact),
            ("latest news",                     .exact),
            ("today news",                      .exact),
            ("show me today's news",            .exact),
            ("news please",                     .exact),
            ("give me the news",                .exact),
            ("news overlay",                    .exact),
            ("show headlines",                  .exact),
        ]),

        def("close_news", "Close News", .news, "Close the news overlay.", .low, [
            ("close news",                      .exact),
            ("hide news",                       .exact),
            ("dismiss news",                    .exact),
            ("get rid of the news",             .exact),
            ("take down news",                  .exact),
            ("turn off news",                   .exact),
        ]),

        def("watch_news", "Watch Live News", .news,
            "Open the news overlay with the live video stream active.", .low, [
            ("watch news",                      .exact),
            ("play news",                       .exact),
            ("watch the news",                  .exact),
            ("play the news",                   .exact),
            ("put the news on",                 .exact),
            ("start the news",                  .exact),
            ("live news",                       .exact),
            ("watch live news",                 .exact),
        ]),

        def("summarise_news", "Summarise News", .news,
            "Give a spoken summary of the top headlines.", .low, [
            ("summarise news",                  .exact,  0),
            ("summarize news",                  .exact,  0),
            ("summarise the news",              .exact,  0),
            ("summarize the news",              .exact,  0),
            ("read headlines",                  .exact,  0),
            ("read the headlines",              .exact,  0),
            ("read me the news",                .exact,  0),
            ("news summary",                    .exact,  0),
            ("brief me on the news",            .exact,  0),
            ("what are the headlines",          .exact, 10),  // higher priority than show_news
            ("what is the latest",              .exact,  0),
            ("headlines please",                .exact,  0),
            ("what is the latest news",         .exact,  0),
        ] as [(String, PhraseMatchType, Int)]),

        def("next_news_channel", "Next Channel", .news, "Switch to the next news channel.", .low, [
            ("next news channel",               .exact),
            ("next channel",                    .exact),
            ("next news",                       .exact),
            ("another channel",                 .exact),
            ("change channel",                  .exact),
            ("switch channel",                  .exact),
        ]),

        def("prev_news_channel", "Previous Channel", .news,
            "Switch to the previous news channel.", .low, [
            ("previous news channel",           .exact),
            ("previous channel",                .exact),
            ("last channel",                    .exact),
            ("go back to last channel",         .exact),
        ]),

        def("refresh_news", "Refresh News", .news, "Refresh all news feeds.", .low, [
            ("refresh news",                    .exact),
            ("update news",                     .exact),
            ("fetch news",                      .exact),
            ("reload news",                     .exact),
        ]),

        def("open_in_browser", "Open in Browser", .news,
            "Open the current article in Safari.", .low, [
            ("open in browser",                 .exact),
            ("open in safari",                  .exact),
            ("open article in browser",         .exact),
            ("open this in browser",            .exact),
        ]),

        def("close_article", "Close Article", .news, "Close the article overlay.", .low, [
            ("close article",                   .exact),
            ("hide article",                    .exact),
            ("close web",                       .exact),
            ("close page",                      .exact),
            ("close webpage",                   .exact),
        ]),

        def("show_saved_news", "Show Saved Articles", .news,
            "Show bookmarked/saved articles.", .low, [
            ("saved news",                      .exact),
            ("saved articles",                  .exact),
            ("my saved articles",               .exact),
            ("show bookmarks",                  .exact),
        ]),

        def("save_news_article", "Save Article", .news, "Bookmark the current article.", .low, [
            ("save this article",               .exact),
            ("save this story",                 .exact),
            ("bookmark this",                   .exact),
            ("save article",                    .exact),
        ]),
    ] }

    // MARK: - Camera

    static var camera: [CommandDefinition] { [
        def("show_camera", "Show Camera", .camera, "Open the live camera overlay.", .low, [
            ("show camera",                     .exact),
            ("open camera",                     .exact),
            ("camera",                          .exact),
            // "show me the camera" → normalises to "show camera" (verbAlias + filler)
            ("show me the camera",              .exact),
            ("show my camera",                  .exact),
            ("show the camera",                 .exact),
            ("show webcam",                     .exact),
            // "can i see camera" → normalises: polite prefix "can i " removed → "see camera"
            // So store both the raw and the expected normalised form:
            ("can i see the camera",            .exact),
            ("see camera",                      .exact),
            ("look through the camera",         .exact),
            ("look through camera",             .exact),
            ("bring up the camera",             .exact),
            ("open my camera",                  .exact),
            ("show me my camera",               .exact),
            ("camera overlay",                  .exact),
            ("wheres my camera",                .exact),
            ("where is my camera",              .exact),
        ]),

        def("close_camera", "Close Camera", .camera, "Close the camera overlay.", .low, [
            ("close camera",                    .exact),
            ("hide camera",                     .exact),
            ("dismiss camera",                  .exact),
            ("turn off camera",                 .exact),
            ("close my camera",                 .exact),
            ("hide my camera",                  .exact),
        ]),

        def("describe_camera", "Describe Camera View", .camera,
            "Ask Jarvis to describe what the camera sees.", .low, [
            // Core vision-query phrases — use .contains so minor STT variations
            // (extra words, wake bleed) still hit the right command.
            ("what can you see",                .contains),
            ("what do you see",                 .contains),
            ("what can you tell me about what you see", .contains),
            ("describe what you see",           .contains),
            ("describe what you can see",       .contains),
            ("describe the view",               .contains),
            ("describe scene",                  .contains),
            ("look around",                     .exact),
            ("what is in front of you",         .contains),
            ("what's in front of you",          .contains),
            ("what do you currently see",       .contains),
            // Natural variants — added so these appear in Settings and are user-editable
            ("what it sees",                    .exact),
            ("what does it see",                .exact),
            ("what can it see",                 .exact),
            ("what is it looking at",           .contains),
            ("what does the camera see",        .contains),
            ("camera sees",                     .contains),
            ("what's on camera",                .contains),
            ("what is on camera",               .contains),
            ("what are you seeing",             .contains),
            ("what are you looking at",         .contains),
            ("describe the camera",             .contains),
        ]),

        def("take_photo", "Take Photo", .camera, "Capture a still image.", .low, [
            ("take a photo",                    .exact),
            ("take a picture",                  .exact),
            ("snap a photo",                    .exact),
            ("capture image",                   .exact),
            ("capture camera",                  .exact),
        ]),

        def("is_anyone_there", "Is Anyone There", .camera,
            "Check if anyone is visible in the camera.", .low, [
            ("is anyone there",                 .exact),
            ("anyone home",                     .exact),
            ("who is there",                    .exact),
            ("can you see anyone",              .exact),
            ("am i visible",                    .exact),
        ]),

        def("describe_person", "Describe Person", .camera,
            "Ask Jarvis to describe the person visible in the camera.", .medium, [
            ("describe the person",             .exact),
            ("describe me",                     .exact),
            ("what do i look like",             .exact),
            ("what does the person look like",  .exact),
            ("what is the person wearing",      .exact),
            ("describe the human",              .exact),
            ("who is in front of you",          .exact),
            ("tell me about the person",        .contains),
        ]),

        def("what_is_on_desk", "What's On My Desk", .camera,
            "Ask Jarvis to describe the objects visible in the camera.", .medium, [
            ("what's on my desk",               .exact),
            ("what is on my desk",              .exact),
            ("what's on the desk",              .exact),
            ("describe my desk",                .exact),
            ("describe the desk",               .exact),
            ("what's on the table",             .exact),
            ("describe the objects",            .exact),
            ("what items can you see",          .exact),
            ("list what you see",               .exact),
        ]),

        def("what_am_i_holding", "What Am I Holding", .camera,
            "Ask Jarvis to identify the object the person is holding in their hands.", .medium, [
            ("what am i holding",               .contains),
            ("what's in my hand",               .contains),
            ("what is in my hand",              .contains),
            ("what am i carrying",              .contains),
            ("what's in my hands",              .contains),
            ("what is in my hands",             .contains),
            ("what have i got",                 .contains),
            ("what do i have in my hand",       .contains),
            ("what am i holding in my hand",    .contains),
            ("what's that in my hand",          .contains),
        ]),
    ] }

    // MARK: - UI

    static var ui: [CommandDefinition] { [
        def("focus_mode", "Focus Mode", .ui,
            "Switch to orb-only focus mode (hide dashboard).", .low, [
            ("focus mode",                      .exact),
            ("orb mode",                        .exact),
            ("minimal mode",                    .exact),
            ("hide dashboard",                  .exact),
            ("go to orb",                       .exact),
            ("back to orb",                     .exact),
        ]),

        def("dashboard_mode", "Dashboard Mode", .ui,
            "Switch to full widget dashboard view.", .low, [
            ("dashboard mode",                  .exact),
            ("show dashboard",                  .exact),
            ("full view",                       .exact),
            ("show widgets",                    .exact),
            ("open dashboard",                  .exact),
            ("dashboard",                       .exact),
        ]),

        def("show_diagnostics", "Show Status/Diagnostics", .ui,
            "Open the status diagnostics overlay.", .low, [
            ("show diagnostics",                .exact),
            ("show status",                     .exact),
            ("status overlay",                  .exact),
            ("show debug",                      .exact),
            ("debug hud",                       .exact),
            ("open status",                     .exact),
        ]),

        def("mode_normal", "Normal Mode", .system, "Return to normal response mode.", .low, [
            ("normal mode",                     .exact),
            ("back to normal",                  .exact),
            ("default mode",                    .exact),
        ]),

        def("mode_concise", "Concise Mode", .system, "Short, brief responses.", .low, [
            ("concise mode",                    .exact),
            ("be concise",                      .exact),
            ("shorter responses",               .exact),
            ("brief mode",                      .exact),
        ]),

        def("mode_silent", "Silent Mode", .system, "Disable spoken responses.", .low, [
            ("silent mode",                     .exact),
            ("go silent",                       .exact),
            ("no talking",                      .exact),
            ("text only",                       .exact),
            ("stop speaking",                   .exact),
        ]),

        def("mode_ambient", "Ambient Mode", .system,
            "Enable ambient background awareness mode.", .low, [
            ("ambient mode",                    .exact),
            ("go ambient",                      .exact),
            ("background mode",                 .exact),
        ]),

        def("show_response_playbook", "Edit Responses", .system,
            "Open the response phrase editor.", .low, [
            ("show response playbook",          .exact),
            ("edit responses",                  .exact),
            ("change how you respond",          .exact),
            ("open response settings",          .exact),
        ]),

        def("show_personality", "Edit Personality", .system,
            "Open the personality settings.", .low, [
            ("show personality",                .exact),
            ("edit personality",                .exact),
            ("personality settings",            .exact),
            ("open personality",                .exact),
        ]),

        def("reload_personality", "Reload Personality", .system,
            "Reload personality files from disk.", .low, [
            ("reload personality",              .exact),
            ("refresh personality",             .exact),
            ("update personality",              .exact),
        ]),
    ] }

    // MARK: - Overlays

    static var overlays: [CommandDefinition] { [
        def("close_overlay", "Close Overlay", .overlays,
            "Close the focused (top-most) overlay.", .low, [
            ("close that",                      .exact),
            ("close this",                      .exact),
            ("hide that",                       .exact),
            ("hide this",                       .exact),
            ("dismiss",                         .exact),
            ("dismiss that",                    .exact),
            ("dismiss this",                    .exact),
            ("close overlay",                   .exact),
            ("hide overlay",                    .exact),
            ("close chat",                      .exact),
            ("hide chat",                       .exact),
        ]),

        def("maximise_overlay", "Maximise Overlay", .overlays,
            "Make the current overlay larger.", .low, [
            ("make this bigger",                .exact),
            ("make it bigger",                  .exact),
            ("make that bigger",                .exact),
            ("maximise overlay",                .exact),
            ("maximize overlay",                .exact),
            ("maximise that",                   .exact),
            ("maximize that",                   .exact),
            ("go fullscreen",                   .exact),
            ("enlarge overlay",                 .exact),
        ]),

        def("minimise_overlay", "Minimise Overlay", .overlays,
            "Make the current overlay smaller or collapse it.", .low, [
            ("make this smaller",               .exact),
            ("make it smaller",                 .exact),
            ("make that smaller",               .exact),
            ("minimise overlay",                .exact),
            ("minimize overlay",                .exact),
            ("minimise that",                   .exact),
            ("minimize that",                   .exact),
            ("shrink that",                     .exact),
        ]),

        def("show_chat", "Show Chat", .overlays, "Open the chat/transcript overlay.", .low, [
            ("show chat",                       .exact),
            ("open chat",                       .exact),
            ("show conversation",               .exact),
            ("show transcript",                 .exact),
            ("open transcript",                 .exact),
            ("chat overlay",                    .exact),
        ]),

        def("show_timeline", "Show Timeline", .overlays,
            "Open the activity timeline overlay.", .low, [
            ("show timeline",                   .exact),
            ("open timeline",                   .exact),
            ("timeline",                        .exact),
            ("what did i do today",             .exact),
            ("today activity",                  .exact),
        ]),

        def("show_reasoning", "Show Reasoning", .overlays,
            "Show the intent reasoning trace.", .low, [
            ("show reasoning",                  .exact),
            ("debug reasoning",                 .exact),
            ("open reasoning",                  .exact),
            ("reasoning overlay",               .exact),
        ]),

        def("pin_overlay", "Pin Overlay", .overlays,
            "Pins the current overlay so it survives close commands.", .low, [
            ("pin this",                        .exact),
            ("pin that",                        .exact),
            ("pin overlay",                     .exact),
            ("pin the overlay",                 .exact),
        ]),

        def("unpin_overlay", "Unpin Overlay", .overlays,
            "Unpins the current overlay so it closes normally.", .low, [
            ("unpin this",                      .exact),
            ("unpin that",                      .exact),
            ("unpin overlay",                   .exact),
            ("unpin the overlay",               .exact),
        ]),

        def("overlay_reset_layout", "Reset Overlay Layout", .overlays,
            "Clears all manual overlay positions, returning to auto-layout.", .low, [
            ("reset layout",                    .exact),
            ("reset overlay layout",            .exact),
            ("snap layout",                     .exact),
            ("reset overlays",                  .exact),
            ("auto layout",                     .exact),
        ]),

        def("overlay_focus_top", "Bring Overlay to Front", .overlays,
            "Brings the most recently opened overlay to the front.", .low, [
            ("bring to front",                  .exact),
            ("focus overlay",                   .exact),
            ("focus that",                      .exact),
        ]),
    ] }

    // MARK: - Time

    static var time: [CommandDefinition] { [
        def("tell_time", "Tell Time", .time, "Speak the current time.", .low, [
            ("what time is it",                 .exact),
            ("what is the time",                .exact),
            ("time please",                     .exact),
            ("tell me the time",                .exact),
            ("time check",                      .exact),
            ("current time",                    .exact),
            ("what time",                       .exact),
            ("time",                            .exact),
        ]),
    ] }

    // MARK: - Memory

    static var memory: [CommandDefinition] { [
        def("remember_last", "Remember Last Response", .memory,
            "Store Jarvis's last spoken response in memory.", .low, [
            ("save this",                       .exact),
            ("save that",                       .exact),
            ("remember that",                   .exact),
            ("remember this",                   .exact),
            ("note that",                       .exact),
            ("note this",                       .exact),
            ("keep that",                       .exact),
        ]),

        def("show_memory", "Show Memory", .memory, "Open the memory browser overlay.", .low, [
            ("show memory",                     .exact),
            ("open memory",                     .exact),
            ("memory overlay",                  .exact),
            ("my memories",                     .exact),
            ("show my memories",                .exact),
        ]),

        def("what_do_you_remember", "What Do You Remember", .memory,
            "Speak a short list of recent memories (no overlay).", .low, [
            ("what do you remember",            .exact),
            ("what have you remembered",        .exact),
            ("tell me what you remember",       .exact),
        ]),

        def("what_was_i_doing", "What Was I Doing", .memory,
            "Recall recent activity from the context snapshot.", .low, [
            ("what was i doing",                .exact),
            ("what was i working on",           .exact),
            ("what have i been doing",          .exact),
            ("what have i been working on",     .exact),
            ("what were we doing",              .exact),
            ("where did i leave off",           .exact),
            ("where did we leave off",          .exact),
        ]),

        def("show_recent_activity", "Show Recent Activity", .memory,
            "Show recent commands and context.", .low, [
            ("show recent activity",            .exact),
            ("recent activity",                 .exact),
            ("recent sessions",                 .exact),
            ("what happened recently",          .exact),
        ]),

        def("search_again", "Search Again", .memory,
            "Repeat the last memory search.", .low, [
            ("search again",                    .exact),
            ("find again",                      .exact),
        ]),
    ] }

    // MARK: - Screen

    static var screen: [CommandDefinition] { [
        def("what_am_i_looking_at", "What Am I Looking At", .screen,
            "Describe the current screen content.", .low, [
            ("what am i looking at",            .exact),
            ("what is on my screen",            .exact),
            ("what is on screen",               .exact),
            ("describe my screen",              .exact),
            ("describe the screen",             .exact),
        ]),

        def("read_my_screen", "Read My Screen", .screen,
            "Read the text visible on screen.", .low, [
            ("read my screen",                  .exact),
            ("read the screen",                 .exact),
            ("read screen",                     .exact),
        ]),

        def("summarise_screen", "Summarise Screen", .screen,
            "Give a brief summary of the current screen.", .low, [
            ("summarise this screen",           .exact),
            ("summarize this screen",           .exact),
            ("summarise my screen",             .exact),
            ("screen summary",                  .exact),
        ]),

        def("capture_screen", "Capture Screen", .screen, "Take a screenshot.", .low, [
            ("capture screen",                  .exact),
            ("screenshot",                      .exact),
            ("take a screenshot",               .exact),
        ]),

        def("watch_screen", "Watch Screen", .screen,
            "Start continuous screen monitoring.", .low, [
            ("watch my screen",                 .exact),
            ("monitor my screen",               .exact),
            ("watch this screen",               .exact),
            ("keep watching",                   .exact),
        ]),

        def("stop_watching_screen", "Stop Watching Screen", .screen,
            "Stop screen monitoring.", .low, [
            ("stop watching screen",            .exact),
            ("stop watching my screen",         .exact),
            ("stop screen watch",               .exact),
        ]),

        def("what_app_am_i_using", "What App Am I Using", .screen,
            "Identify the frontmost application.", .low, [
            ("what app am i using",             .exact),
            ("which app am i using",            .exact),
            ("what application am i using",     .exact),
            ("what am i using",                 .exact),
        ]),

        def("show_screen", "Show Screen Overlay", .screen,
            "Open the screen awareness overlay.", .low, [
            ("show screen overlay",             .exact),
            ("screen overlay",                  .exact),
            ("show screen",                     .exact),
            ("screen awareness",                .exact),
        ]),

        // Ambient Context
        def("what_am_i_working_on", "What Am I Working On", .screen,
            "Speaks the current ambient context summary.", .medium, [
            ("what am i working on",            .exact),
            ("what am i doing",                 .exact),
            ("what are we working on",          .exact),
            ("what's my current task",          .exact),
            ("what task am i on",               .exact),
        ]),

        def("what_failed_on_screen", "What Failed on Screen", .screen,
            "Reports any errors or build failures detected on screen.", .medium, [
            ("what failed",                     .exact),
            ("what's the error",                .exact),
            ("what error is there",             .exact),
            ("what broke",                      .exact),
            ("any errors",                      .exact),
            ("show errors",                     .exact),
        ]),

        def("what_changed_on_screen", "What Changed on Screen", .screen,
            "Describes what changed since the last ambient context snapshot.", .low, [
            ("what changed",                    .exact),
            ("what's different",                .exact),
            ("what changed on screen",          .exact),
        ]),

        def("watch_this", "Watch This", .screen,
            "Activate watch mode — boost sampling frequency for the current app.", .high, [
            ("watch this",                      .exact),
            ("monitor this",                    .exact),
            ("keep an eye on this",             .exact),
            ("watch this build",                .exact),
            ("watch this window",               .exact),
            ("start watching",                  .exact),
        ]),

        def("stop_watching", "Stop Watching", .screen,
            "Deactivate watch mode and return to normal sampling frequency.", .medium, [
            ("stop watching",                   .exact),
            ("stop monitoring",                 .exact),
            ("stop keeping an eye",             .contains),
            ("cancel watch mode",               .exact),
        ]),

        def("enable_ambient_context", "Enable Ambient Context", .screen,
            "Resume background app and screen awareness.", .low, [
            ("enable ambient context",          .exact),
            ("start ambient context",           .exact),
            ("enable background awareness",     .exact),
            ("turn on ambient context",         .exact),
        ]),

        def("disable_ambient_context", "Disable Ambient Context", .screen,
            "Pause background app and screen awareness.", .low, [
            ("disable ambient context",         .exact),
            ("pause ambient context",           .exact),
            ("disable background awareness",    .exact),
            ("turn off ambient context",        .exact),
        ]),

        def("show_ambient_context_overlay", "Show Ambient Context Overlay", .screen,
            "Open the ambient context debug overlay.", .low, [
            ("show ambient context",            .exact),
            ("ambient context overlay",         .exact),
            ("show context debug",              .exact),
            ("ambient debug",                   .exact),
        ]),

        def("show_speech_latency", "Show Speech Latency", .screen,
            "Open the speech-to-speech latency diagnostics overlay.", .low, [
            ("speech latency",                  .exact),
            ("show speech latency",             .exact),
            ("latency diagnostics",             .exact),
            ("pipeline timing",                 .exact),
        ]),

        def("show_voice_lab", "Show Voice Lab", .screen,
            "Open the Voice Lab for TTS backend comparison and benchmarking.", .low, [
            ("voice lab",                       .exact),
            ("show voice lab",                  .exact),
            ("tts comparison",                  .exact),
            ("voice benchmark",                 .exact),
        ]),

        def("show_runtime_diagnostics", "Show Runtime Diagnostics", .screen,
            "Open the runtime subsystem health overlay.", .low, [
            ("runtime diagnostics",             .exact),
            ("show runtime diagnostics",        .exact),
            ("subsystem health",                .exact),
            ("system runtime",                  .exact),
        ]),

        def("show_focus", "Show Focus", .screen,
            "Open the focus diagnostics overlay and speak the current project focus summary.", .low, [
            ("show focus",                      .exact),
            ("show context graph",              .exact),
            ("open context graph",              .exact),
            ("focus state",                     .exact),
            ("show recent work sessions",       .exact),
            ("context graph",                   .exact),
        ]),

        def("explain_current_focus", "Explain Current Focus", .screen,
            "Explain why Jarvis believes you are focused on a particular project.", .low, [
            ("why do you think that",           .exact),
            ("explain current focus",           .exact),
            ("what project am i focused on",    .exact),
            ("what are you basing that on",     .exact),
            ("how confident are you about that",.exact),
            ("explain your focus",              .exact),
            ("why that project",                .exact),
        ]),

        def("show_spatial_interaction", "Spatial Interaction Mode", .screen,
            "Launch the hand-tracking spatial overlay — raise palm to interact.", .medium, [
            ("spatial mode",                    .exact),
            ("hand mode",                       .exact),
            ("open spatial",                    .exact),
            ("launch spatial",                  .exact),
            ("spatial interaction",             .exact),
            ("hand tracking mode",              .exact),
            ("gesture mode",                    .exact),
            ("spatial interface",               .exact),
        ]),

        def("hide_spatial_interaction", "Close Spatial Mode", .screen,
            "Dismiss the spatial interaction overlay.", .low, [
            ("close spatial",                   .exact),
            ("exit spatial",                    .exact),
            ("close hand mode",                 .exact),
            ("exit gesture mode",               .exact),
            ("disable spatial",                 .exact),
        ]),
    ] }

    // MARK: - System

    static var system: [CommandDefinition] { [
        def("status", "System Status", .system, "Speak a brief system status summary.", .low, [
            ("system status",                   .exact),
            ("how are you",                     .exact),
            ("status",                          .exact),
            ("how is everything",               .exact),
        ]),

        def("repeat_last", "Repeat Last", .system,
            "Repeat Jarvis's last spoken response.", .low, [
            ("repeat that",                     .exact),
            ("say that again",                  .exact),
            ("say again",                       .exact),
            ("repeat",                          .exact),
            ("repeat please",                   .exact),
        ]),

        def("stop_talking", "Stop Talking", .system,
            "Immediately stop Jarvis speaking.", .low, [
            ("stop talking",                    .exact),
            ("be quiet",                        .exact),
            ("shut up",                         .exact),
            ("stop",                            .exact),
            ("enough",                          .exact),
        ]),

        def("why_did_you_do_that", "Why Did You Do That", .system,
            "Show the reasoning trace for the last action.", .low, [
            ("why did you do that",             .exact),
            ("why did you say that",            .exact),
            ("explain that",                    .exact),
            ("explain what you did",            .exact),
        ]),

        def("show_attention_state", "Show Attention State", .system,
            "Show the current attention/presence detection state.", .low, [
            ("show attention state",            .exact),
            ("show attention",                  .exact),
            ("attention state",                 .exact),
        ]),

        // NOTE: home_status is defined in the homeAssistant section below (canonical).
    ] }

    // MARK: - Small Talk

    static var smallTalk: [CommandDefinition] { [
        def("can_you_hear_me", "Can You Hear Me", .smallTalk,
            "Sanity-check — confirm Jarvis is receiving audio.", .low, [
            ("can you hear me",                 .exact),
            ("do you hear me",                  .exact),
            ("hear me",                         .exact),
            ("are you there",                   .exact),
            ("hello jarvis",                    .exact),
            ("you there",                       .exact),
        ]),

        def("are_you_listening", "Are You Listening", .smallTalk,
            "Confirm Jarvis is in listening mode.", .low, [
            ("are you listening",               .exact),
            ("still listening",                 .exact),
            ("you listening",                   .exact),
        ]),
    ] }

    // MARK: - Identity

    static var identity: [CommandDefinition] { [
        def("ask_my_name", "What Is My Name", .system,
            "Answer the user's name from preferences.", .low, [
            ("what is my name",                 .exact),
            ("what's my name",                  .exact),
            ("do you know my name",             .exact),
            ("who am i",                        .exact),
        ]),

        def("ask_assistant_name", "What Is Your Name", .system,
            "Tell the user the assistant's name.", .low, [
            ("what is your name",               .exact),
            ("what's your name",                .exact),
            ("who are you",                     .exact),
            ("what are you called",             .exact),
            ("tell me your name",               .exact),
            ("your name",                       .exact),
        ]),

        def("ask_personal_facts", "What Do You Know About Me", .system,
            "Speak known personal facts from preferences and memory.", .low, [
            ("what do you know about me",       .exact),
            ("tell me what you know about me",  .exact),
            ("what have you learned about me",  .exact),
            ("what do you know of me",          .exact),
            ("personal facts",                  .exact),
        ]),
    ] }

    // MARK: - Listening

    static var listening: [CommandDefinition] { [
        def("stop_listening", "Stop Listening", .listening,
            "Mute wake-word detection.", .medium, [
            ("stop listening",                  .exact),
            ("go quiet",                        .exact),
            ("go to sleep",                     .exact),
            ("sleep",                           .exact),
            ("disable listening",               .exact),
            ("disable wake word",               .exact),
            ("shut down listening",             .exact),
        ]),

        def("start_listening", "Start Listening", .listening,
            "Re-enable wake-word detection.", .medium, [
            ("start listening",                 .exact),
            ("wake up",                         .exact),
            ("resume listening",                .exact),
            ("enable listening",                .exact),
            ("begin listening",                 .exact),
        ]),
    ] }

    // MARK: - Apps

    static var apps: [CommandDefinition] { [
        def("open_app", "Open App", .apps,
            "Open any installed app by name.", .low, [
            ("open",                            .startsWith),
            ("launch",                          .startsWith),
            ("start",                           .startsWith),
            ("bring up",                        .startsWith),
            ("run",                             .startsWith),
        ]),

        def("open_app_on_phone", "Open App on Phone", .apps,
            "Open an app on the connected Android phone.", .low, [
            ("open",                            .startsWith),
            ("launch",                          .startsWith),
        ]),

        def("activate_app", "Switch to App", .apps,
            "Bring a running app to the front.", .low, [
            ("switch to",                       .startsWith),
            ("go to",                           .startsWith),
            ("show me",                         .startsWith),
            ("bring back",                      .startsWith),
            ("focus",                           .startsWith),
        ]),

        def("list_running_apps", "List Running Apps", .apps,
            "Speak a list of currently running applications.", .low, [
            ("what apps are running",           .exact),
            ("list running apps",               .exact),
            ("what is running",                 .exact),
            ("which apps are open",             .exact),
            ("what have i got open",            .exact),
            ("running apps",                    .exact),
        ]),
    ] }

    // MARK: - System Settings

    static var systemSettings: [CommandDefinition] { [
        def("open_settings", "Open System Settings", .systemSettings,
            "Open System Settings.", .low, [
            ("open settings",                   .exact),
            ("open system settings",            .exact),
            ("system settings",                 .exact),
            ("show settings",                   .exact),
            ("settings",                        .exact),
            ("open preferences",                .exact),
            ("system preferences",              .exact),
        ]),

        def("open_settings_wifi", "Wi-Fi Settings", .systemSettings,
            "Open the Wi-Fi settings pane.", .low, [
            ("open wifi settings",              .exact),
            ("wifi settings",                   .exact),
            ("show wifi settings",              .exact),
            ("open wi-fi settings",             .exact),
            ("network settings",                .exact),
        ]),

        def("open_settings_bluetooth", "Bluetooth Settings", .systemSettings,
            "Open the Bluetooth settings pane.", .low, [
            ("open bluetooth settings",         .exact),
            ("bluetooth settings",              .exact),
            ("show bluetooth settings",         .exact),
            ("bluetooth",                       .exact),
        ]),

        def("open_settings_sound", "Sound Settings", .systemSettings,
            "Open the Sound settings pane.", .low, [
            ("open sound settings",             .exact),
            ("sound settings",                  .exact),
            ("audio settings",                  .exact),
            ("open audio settings",             .exact),
        ]),

        def("open_settings_display", "Display Settings", .systemSettings,
            "Open the Display settings pane.", .low, [
            ("open display settings",           .exact),
            ("display settings",                .exact),
            ("screen settings",                 .exact),
            ("open screen settings",            .exact),
        ]),

        def("open_settings_privacy", "Privacy & Security Settings", .systemSettings,
            "Open Privacy & Security settings.", .low, [
            ("open privacy settings",           .exact),
            ("privacy settings",                .exact),
            ("security settings",               .exact),
            ("open security settings",          .exact),
            ("privacy and security",            .exact),
        ]),

        def("open_settings_notifications", "Notification Settings", .systemSettings,
            "Open Notification settings.", .low, [
            ("open notification settings",      .exact),
            ("notification settings",           .exact),
            ("notifications settings",          .exact),
            ("open notifications settings",     .exact),
        ]),

        def("open_settings_keyboard", "Keyboard Settings", .systemSettings,
            "Open Keyboard settings.", .low, [
            ("open keyboard settings",          .exact),
            ("keyboard settings",               .exact),
        ]),

        def("open_settings_battery", "Battery Settings", .systemSettings,
            "Open Battery / Energy settings.", .low, [
            ("open battery settings",           .exact),
            ("battery settings",                .exact),
            ("energy settings",                 .exact),
            ("open energy settings",            .exact),
        ]),

        def("open_settings_accessibility", "Accessibility Settings", .systemSettings,
            "Open Accessibility settings.", .low, [
            ("open accessibility settings",     .exact),
            ("accessibility settings",          .exact),
        ]),
    ] }

    // MARK: - Volume

    static var volume: [CommandDefinition] { [
        def("volume_up", "Volume Up", .volume, "Increase system volume.", .low, [
            ("volume up",                       .exact),
            ("turn it up",                      .exact),
            ("turn up the volume",              .exact),
            ("louder",                          .exact),
            ("make it louder",                  .exact),
            ("increase volume",                 .exact),
            ("raise the volume",                .exact),
            ("raise volume",                    .exact),
            ("bit louder",                      .contains),
        ]),

        def("volume_down", "Volume Down", .volume, "Decrease system volume.", .low, [
            ("volume down",                     .exact),
            ("turn it down",                    .exact),
            ("turn down the volume",            .exact),
            ("quieter",                         .exact),
            ("make it quieter",                 .exact),
            ("decrease volume",                 .exact),
            ("lower the volume",                .exact),
            ("lower volume",                    .exact),
            ("bit quieter",                     .contains),
        ]),

        def("mute", "Mute", .volume, "Mute system audio.", .low, [
            ("mute",                            .exact),
            ("silence",                         .exact),
            ("no sound",                        .exact),
            ("turn off the sound",              .exact),
            ("turn off sound",                  .exact),
            ("mute the sound",                  .exact),
            ("mute audio",                      .exact),
        ]),

        def("unmute", "Unmute", .volume, "Unmute system audio.", .low, [
            ("unmute",                          .exact),
            ("turn the sound back on",          .exact),
            ("restore sound",                   .exact),
            ("turn sound on",                   .exact),
            ("unmute audio",                    .exact),
        ]),

        def("get_volume", "Get Volume", .volume, "Speak the current volume level.", .low, [
            ("what volume is it",               .exact),
            ("what is the volume",              .exact),
            ("how loud is it",                  .exact),
            ("current volume",                  .exact),
            ("volume level",                    .exact),
        ]),
    ] }

    // MARK: - Files

    static var files: [CommandDefinition] { [
        def("open_downloads", "Open Downloads", .files,
            "Open the Downloads folder.", .low, [
            ("open downloads",                  .exact),
            ("show downloads",                  .exact),
            ("downloads folder",                .exact),
            ("go to downloads",                 .exact),
        ]),

        def("open_desktop", "Open Desktop", .files,
            "Open the Desktop folder in Finder.", .low, [
            ("open desktop folder",             .exact),
            ("show desktop folder",             .exact),
            ("go to desktop",                   .exact),
            ("desktop folder",                  .exact),
        ]),

        def("open_documents", "Open Documents", .files,
            "Open the Documents folder.", .low, [
            ("open documents",                  .exact),
            ("show documents",                  .exact),
            ("documents folder",                .exact),
            ("go to documents",                 .exact),
        ]),

        def("open_latest_download", "Open Latest Download", .files,
            "Open the most recently downloaded file.", .low, [
            ("open latest download",            .exact),
            ("open my latest download",         .exact),
            ("open last download",              .exact),
            ("latest download",                 .exact),
            ("most recent download",            .exact),
            ("what did i just download",        .exact),
        ]),
    ] }

    // MARK: - Windows

    static var windows: [CommandDefinition] { [
        def("show_desktop", "Show Desktop", .windows,
            "Hide all windows and show the desktop.", .low, [
            ("show desktop",                    .exact),
            ("show the desktop",                .exact),
            ("hide all windows",                .exact),
            ("clear the screen",                .exact),
        ]),

        def("lock_screen", "Lock Screen", .windows,
            "Lock the screen immediately.", .medium, [
            ("lock screen",                     .exact),
            ("lock my screen",                  .exact),
            ("lock the screen",                 .exact),
            ("lock the mac",                    .exact),
            ("lock computer",                   .exact),
        ]),

        def("sleep_display", "Sleep Display", .windows,
            "Turn off the display (sleep it).", .low, [
            ("sleep display",                   .exact),
            ("sleep the display",               .exact),
            ("turn off the screen",             .exact),
            ("turn off display",                .exact),
            ("display sleep",                   .exact),
        ]),

        def("quit_app", "Quit App", .windows,
            "Quit a running application.", .medium, [
            ("quit",                            .startsWith),
            ("close app",                       .startsWith),
            ("exit",                            .startsWith),
            ("force quit",                      .startsWith),
        ]),

        def("hide_app", "Hide App", .windows,
            "Hide an application window.", .low, [
            ("hide",                            .startsWith),
        ]),
    ] }

    // MARK: - Proactivity

    static var proactivity: [CommandDefinition] { [

        def("show_notifications", "Show Notifications", .system,
            "Show pending proactive notifications.", .low, [
            ("what needs my attention",          .exact),
            ("show notifications",               .exact),
            ("show my notifications",            .exact),
            ("any notifications",                .contains),
            ("anything i should know",           .contains),
            ("check notifications",              .exact),
            ("notification centre",              .exact),
        ]),

        def("dismiss_notifications", "Clear Notifications", .system,
            "Dismiss all pending notifications.", .low, [
            ("clear notifications",              .exact),
            ("dismiss all notifications",        .exact),
            ("dismiss notifications",            .exact),
            ("clear all notifications",          .exact),
        ]),

        def("pause_proactivity", "Pause Proactivity", .system,
            "Pause all proactive notifications.", .low, [
            ("pause proactivity",                .exact),
            ("pause notifications",              .exact),
            ("stop notifying me",                .exact),
            ("stop proactivity",                 .exact),
            ("disable proactive notifications",  .exact),
        ]),

        def("resume_proactivity", "Resume Proactivity", .system,
            "Resume proactive notifications.", .low, [
            ("resume proactivity",               .exact),
            ("resume notifications",             .exact),
            ("start notifying me",               .exact),
            ("enable proactive notifications",   .exact),
        ]),

        def("mute_news_hour", "Mute News for an Hour", .system,
            "Silence news notifications for one hour.", .low, [
            ("mute news for an hour",            .exact),
            ("mute news for 1 hour",             .exact),
            ("snooze news for an hour",          .exact),
            ("quiet news for an hour",           .exact),
        ]),

        def("mute_news", "Mute News", .system,
            "Silence news notifications indefinitely.", .low, [
            ("mute news",                        .exact),
            ("stop news alerts",                 .exact),
            ("disable news alerts",              .exact),
            ("turn off news notifications",      .exact),
        ]),

        def("unmute_news", "Unmute News", .system,
            "Re-enable news notifications.", .low, [
            ("unmute news",                      .exact),
            ("enable news alerts",               .exact),
            ("resume news alerts",               .exact),
            ("turn on news notifications",       .exact),
        ]),

        def("open_that_story", "Open That Story", .system,
            "Open the last proactively-announced news story.", .low, [
            ("open that story",                  .exact),
            ("open that article",                .exact),
            ("open the article",                 .exact),
            ("open that",                        .exact),
            ("show me that story",               .exact),
        ]),

        def("summarise_that", "Summarise That", .system,
            "Summarise the last proactively-announced story.", .low, [
            ("summarise that",                   .exact),
            ("summarize that",                   .exact),
            ("summarise the story",              .exact),
            ("tell me more about that",          .exact),
            ("give me the details",              .exact),
        ]),

        def("show_latest_alert", "Show Me That", .system,
            "Open the overlay for the latest proactive alert (any source).", .low, [
            ("show me",                          .exact),
            ("show me that",                     .exact),
            ("what was that",                    .exact),
            ("what did you just say",            .exact),
            ("open that alert",                  .exact),
            ("show me the alert",                .exact),
        ]),

        def("dismiss_latest_alert", "Dismiss That", .system,
            "Dismiss the latest proactive alert.", .low, [
            ("dismiss that",                     .exact),
            ("dismiss the alert",                .exact),
            ("never mind",                       .exact),
            ("ignore that",                      .exact),
            ("close the alert",                  .exact),
        ]),

        def("proactivity_useful", "That Was Useful", .system,
            "Positive feedback on the last notification.", .low, [
            ("that was useful",                  .exact),
            ("useful",                           .exact),
            ("good notification",                .exact),
            ("keep telling me this",             .exact),
        ]),

        def("proactivity_not_useful", "Not Useful", .system,
            "Negative feedback on the last notification.", .low, [
            ("not useful",                       .exact),
            ("not helpful",                      .exact),
            ("that wasn't useful",               .exact),
            ("bad notification",                 .exact),
            ("i didn't need to know that",       .exact),
        ]),

        def("never_tell_me_this", "Don't Tell Me About This", .system,
            "Suppress this type of notification permanently.", .low, [
            ("don't tell me about this",         .exact),
            ("stop telling me about this",       .exact),
            ("ignore stories like that",         .exact),
            ("never show me this",               .exact),
        ]),

        def("always_tell_me_this", "Always Tell Me About This", .system,
            "Boost priority for this notification type.", .low, [
            ("always tell me about this",        .exact),
            ("always notify me about this",      .exact),
            ("i want to hear about this",        .exact),
        ]),

    ] }

    // MARK: - Home Assistant

    static var homeAssistant: [CommandDefinition] { [

        def("home_status", "Home Status", .homeAssistant,
            "Summarise smart home status.", .low, [
            ("home status",                      .exact),
            ("smart home status",                .exact),
            ("show home",                        .exact),
            ("what is at home",                  .exact),
            ("what is happening at home",        .exact),
        ]),

        def("home_turn_on", "Turn On Device", .homeAssistant,
            "Turn on a Home Assistant device by name.", .low, [
            ("turn on",                          .startsWith),
            ("switch on",                        .startsWith),
            ("light on",                         .startsWith),
        ]),

        def("home_turn_off", "Turn Off Device", .homeAssistant,
            "Turn off a Home Assistant device by name.", .low, [
            ("turn off",                         .startsWith),
            ("switch off",                       .startsWith),
            ("light off",                        .startsWith),
            ("shut off",                         .startsWith),
        ]),

        def("home_set_brightness", "Set Brightness", .homeAssistant,
            "Set light brightness by name and percentage.", .low, [
            ("dim",                              .startsWith),
            ("brighten",                         .startsWith),
            ("set brightness",                   .startsWith),
            ("set the brightness",               .startsWith),
            ("brightness to",                    .contains),
        ]),

        def("home_set_color", "Set Light Color", .homeAssistant,
            "Change a light's color.", .low, [
            ("set color",                        .startsWith),
            ("set colour",                       .startsWith),
            ("change color",                     .startsWith),
            ("change colour",                    .startsWith),
            ("make it",                          .startsWith),
            ("turn it",                          .startsWith),
        ]),

        def("home_activate_scene", "Activate Scene", .homeAssistant,
            "Activate a Home Assistant scene.", .low, [
            ("activate scene",                   .startsWith),
            ("scene",                            .startsWith),
            ("set scene",                        .startsWith),
            ("run scene",                        .startsWith),
        ]),

        def("home_open_cover", "Open Cover", .homeAssistant,
            "Open a cover, blind, or garage door.", .low, [
            ("open the garage",                  .exact),
            ("open garage",                      .exact),
            ("open the blinds",                  .exact),
            ("open the blind",                   .exact),
            ("open blinds",                      .exact),
            ("open the shutter",                 .exact),
            ("open shutter",                     .exact),
            ("open cover",                       .startsWith),
        ]),

        def("home_close_cover", "Close Cover", .homeAssistant,
            "Close a cover, blind, or garage door.", .low, [
            ("close the garage",                 .exact),
            ("close garage",                     .exact),
            ("close the blinds",                 .exact),
            ("close the blind",                  .exact),
            ("close blinds",                     .exact),
            ("close the shutter",                .exact),
            ("close shutter",                    .exact),
            ("close cover",                      .startsWith),
        ]),

        def("check_lock", "Check Lock Status", .homeAssistant,
            "Query whether a smart lock is locked or unlocked.", .medium, [
            ("is the front door locked",            .exact),
            ("is the front door unlocked",          .exact),
            ("is front door locked",                .exact),
            ("is front door unlocked",              .exact),
            ("is the back door locked",             .exact),
            ("is the back door unlocked",           .exact),
            ("is the door locked",                  .exact),
            ("is the door unlocked",                .exact),
            ("check the lock",                      .exact),
            ("check the front door lock",           .exact),
            ("check front door",                    .exact),
            ("is locked",                           .contains),
            ("is unlocked",                         .contains),
        ]),

        def("home_lock", "Lock Door", .homeAssistant,
            "Lock a smart lock.", .medium, [
            ("lock the door",                    .exact),
            ("lock door",                        .exact),
            ("lock front door",                  .exact),
            ("lock the front door",              .exact),
            ("lock",                             .startsWith),
        ]),

        def("home_unlock", "Unlock Door", .homeAssistant,
            "Unlock a smart lock.", .medium, [
            ("unlock the door",                  .exact),
            ("unlock door",                      .exact),
            ("unlock front door",                .exact),
            ("unlock the front door",            .exact),
            ("unlock",                           .startsWith),
        ]),

        def("home_show_camera", "Show HA Camera", .homeAssistant,
            "Show a Home Assistant camera entity.", .low, [
            ("show camera",                      .startsWith),
            ("show the camera",                  .startsWith),
            ("show front door camera",           .exact),
            ("show front door",                  .exact),
            ("show backyard",                    .contains),
            ("show driveway",                    .contains),
            ("show doorbell",                    .contains),
        ]),

    ] }

    // MARK: - HA Automations

    static var haAutomations: [CommandDefinition] { [
        def("home_run_automation", "Run HA Automation", .homeAssistant,
            "Trigger a Home Assistant automation by name.", .medium, [
            ("run automation",          .startsWith),
            ("trigger automation",      .startsWith),
            ("activate automation",     .startsWith),
            ("run the automation",      .contains),
        ]),
    ] }

    // MARK: - Calendar

    static var calendar: [CommandDefinition] { [

        def("show_calendar", "Show Calendar", .calendar,
            "Open the calendar overlay.", .low, [
            ("show calendar",                    .exact),
            ("open calendar",                    .exact),
            ("calendar",                         .exact),
            ("show my calendar",                 .exact),
            ("open my calendar",                 .exact),
            ("calendar overlay",                 .exact),
        ]),

        def("next_meeting", "Next Meeting", .calendar,
            "Tell me when my next meeting is.", .low, [
            ("next meeting",                     .exact),
            ("when is my next meeting",          .exact),
            ("what is my next meeting",          .exact),
            ("my next meeting",                  .exact),
            ("next appointment",                 .exact),
            ("when is my next appointment",      .exact),
            ("what is my next appointment",      .exact),
        ]),

        def("meetings_today", "Meetings Today", .calendar,
            "List today's calendar events.", .low, [
            ("what is on my calendar",           .exact),
            ("what is on my calendar today",     .exact),
            ("meetings today",                   .exact),
            ("my meetings today",                .exact),
            ("what do i have today",             .exact),
            ("what have i got today",            .exact),
            ("today's meetings",                 .exact),
            ("todays meetings",                  .exact),
            ("appointments today",               .exact),
            ("schedule today",                   .exact),
        ]),

        def("add_reminder", "Add Reminder", .calendar,
            "Add a reminder to the calendar.", .low, [
            ("remind me to",                     .startsWith),
            ("remind me about",                  .startsWith),
            ("add reminder",                     .startsWith),
            ("set a reminder",                   .startsWith),
            ("create reminder",                  .startsWith),
        ]),

    ] }

    // MARK: - Todoist

    static var todoist: [CommandDefinition] { [

        def("show_tasks", "Show Tasks", .todoist,
            "Show my Todoist task list.", .low, [
            ("show tasks",                       .exact),
            ("show my tasks",                    .exact),
            ("open tasks",                       .exact),
            ("my tasks",                         .exact),
            ("task list",                        .exact),
            ("show to do list",                  .exact),
            ("show todo list",                   .exact),
            ("show my to do list",               .exact),
        ]),

        def("what_are_my_tasks", "What Are My Tasks", .todoist,
            "Speak a summary of pending tasks.", .low, [
            ("what are my tasks",                .exact),
            ("what tasks do i have",             .exact),
            ("what is on my to do list",         .exact),
            ("what is on my todo list",          .exact),
            ("read my tasks",                    .exact),
            ("what do i need to do",             .exact),
        ]),

        def("add_task", "Add Task", .todoist,
            "Add a task to Todoist.", .low, [
            ("add task",                         .startsWith),
            ("new task",                         .startsWith),
            ("create task",                      .startsWith),
            ("add to my list",                   .startsWith),
            ("add to my to do list",             .startsWith),
            ("add to todoist",                   .startsWith),
        ]),

        def("complete_task", "Complete Task", .todoist,
            "Mark a task as complete.", .low, [
            ("complete task",                    .startsWith),
            ("finish task",                      .startsWith),
            ("done with",                        .startsWith),
            ("mark as done",                     .startsWith),
            ("check off",                        .startsWith),
            ("mark complete",                    .startsWith),
        ]),

        def("overdue_tasks", "Overdue Tasks", .todoist,
            "Show overdue tasks.", .low, [
            ("overdue tasks",                    .exact),
            ("what is overdue",                  .exact),
            ("what tasks are overdue",           .exact),
            ("show overdue tasks",               .exact),
            ("any overdue tasks",                .exact),
            ("late tasks",                       .exact),
        ]),

    ] }

    // MARK: - Calendar Overlay

    static var calendarOverlay: [CommandDefinition] { [
        def("show_calendar_overlay", "Show Calendar", .ui,
            "Open the calendar overlay showing today's events.", .low, [
            ("show calendar",           .exact),
            ("open calendar",           .exact),
            ("my calendar",             .exact),
            ("calendar overlay",        .exact),
            ("show my calendar",        .exact),
            ("today's events",          .exact),
            ("what are my events",      .exact),
            ("what's on my calendar",   .exact),
        ]),
    ] }

    // MARK: - Tasks Overlay

    static var tasksOverlay: [CommandDefinition] { [
        def("show_tasks_overlay", "Show Tasks", .ui,
            "Open the tasks overlay showing your Todoist list.", .low, [
            ("show tasks",              .exact),
            ("open tasks",              .exact),
            ("my tasks",                .exact),
            ("task list",               .exact),
            ("tasks overlay",           .exact),
            ("show my tasks",           .exact),
            ("open my task list",       .exact),
            ("what are my tasks",       .exact),
        ]),
    ] }

    // MARK: - Weather

    static var weather: [CommandDefinition] { [
        def("current_weather", "Current Weather", .system,
            "Ask Jarvis what the current weather is.", .low, [
            ("weather",                         .exact),
            ("what's the weather",              .exact),
            ("how's the weather",               .exact),
            ("weather today",                   .exact),
            ("current weather",                 .exact),
            ("what is the weather",             .exact),
            ("what is the weather like",        .exact),
            ("how hot is it",                   .exact),
            ("how cold is it",                  .exact),
            ("what's the temperature",          .exact),
            ("what's it like outside",          .exact),
            ("weather outside",                 .exact),
            ("weather right now",               .exact),
            ("will it rain",                    .exact),
            ("will it rain today",              .exact),
            ("do i need an umbrella",           .exact),
            ("should i bring an umbrella",      .exact),
        ]),
        def("weather_forecast", "Weather Forecast", .system,
            "Ask Jarvis for the weather forecast.", .low, [
            ("forecast",                        .exact),
            ("what's the forecast",             .exact),
            ("weather forecast",                .exact),
            ("weather tomorrow",                .exact),
            ("forecast for tomorrow",           .exact),
            ("weather this week",               .exact),
            ("weekly forecast",                 .exact),
            ("5 day forecast",                  .exact),
            ("will it rain tomorrow",           .exact),
        ]),
    ] }

    // MARK: - Help

    static var help: [CommandDefinition] { [
        def("jarvis_help", "Jarvis Help", .ui,
            "Ask Jarvis what it can do.", .low, [
            ("help",                            .exact),
            ("what can you do",                 .exact),
            ("what can you help with",          .exact),
            ("what are your capabilities",      .exact),
            ("what commands do you know",       .exact),
            ("how can you help",                .exact),
            ("list commands",                   .exact),
            ("what are your commands",          .exact),
            ("show me what you can do",         .exact),
            ("jarvis help",                     .exact),
        ]),
    ] }

    // MARK: - Briefing

    static var briefing: [CommandDefinition] { [
        def("daily_briefing", "Daily Briefing", .ui,
            "Get a combined summary of news, calendar, and tasks.", .low, [
            ("what did i miss",                 .exact),
            ("daily briefing",                  .exact),
            ("morning briefing",                .exact),
            ("give me a summary",               .exact),
            ("brief me",                        .exact),
            ("catch me up",                     .exact),
            ("what's new",                      .exact),
            ("rundown",                         .exact),
            ("briefing",                        .exact),
            ("what's going on today",           .exact),
            ("give me the rundown",             .exact),
        ]),
    ] }

    // MARK: - Home Overlay

    static var homeOverlay: [CommandDefinition] { [
        def("show_home_overlay", "Show Home Overlay", .homeAssistant,
            "Opens the smart home entity grid.", .low, [
            ("home overlay",            .exact),
            ("home panel",              .exact),
            ("smart home panel",        .exact),
            ("smart home overlay",      .exact),
            ("show devices",            .exact),
            ("open devices",            .exact),
            ("my devices",              .exact),
            ("show my devices",         .exact),
            ("home grid",               .exact),
        ]),
    ] }

    // MARK: - HA Camera Overlays

    static var haCameras: [CommandDefinition] { [

        def("show_ha_camera", "Show Camera", .homeAssistant,
            "Open a specific Home Assistant camera by name.", .high, [
            ("show camera",                 .startsWith),
            ("open camera",                 .startsWith),
            ("show the camera",             .startsWith),
            ("open the camera",             .startsWith),
            ("show front door camera",      .exact),
            ("open front door camera",      .exact),
            ("show doorbell camera",        .exact),
            ("show ring camera",            .exact),
            ("show porch camera",           .exact),
            ("show driveway camera",        .exact),
            ("show living room camera",     .exact),
            ("show backyard camera",        .exact),
            ("show garden camera",          .exact),
            ("show garage camera",          .exact),
            ("front door camera",           .exact),
            ("doorbell camera",             .exact),
            ("ring camera",                 .exact),
            ("pull up the camera",          .startsWith),
            ("bring up the camera",         .startsWith),
        ]),

        def("close_ha_camera", "Close Camera", .homeAssistant,
            "Close the Home Assistant camera overlay.", .high, [
            ("close camera",                .exact),
            ("close the camera",            .exact),
            ("hide camera",                 .exact),
            ("dismiss camera",              .exact),
            ("close front door camera",     .exact),
            ("close doorbell camera",       .exact),
            ("close ring camera",           .exact),
            ("turn off camera",             .exact),
        ]),

        def("show_all_cameras", "Show All Cameras", .homeAssistant,
            "Open a grid view of all Home Assistant cameras.", .low, [
            ("show all cameras",            .exact),
            ("open all cameras",            .exact),
            ("all cameras",                 .exact),
            ("camera grid",                 .exact),
            ("show cameras",                .exact),
            ("show my cameras",             .exact),
            ("camera overview",             .exact),
        ]),

        def("mute_ha_alerts", "Mute Home Alerts", .homeAssistant,
            "Mute proactive Home Assistant camera and motion alerts for one hour.", .low, [
            ("mute home alerts",            .exact),
            ("mute doorbell alerts",        .exact),
            ("mute motion alerts",          .exact),
            ("mute camera alerts",          .exact),
            ("mute ha alerts",              .exact),
            ("stop camera alerts",          .exact),
            ("disable motion alerts",       .exact),
            ("quiet the doorbell",          .exact),
        ]),

        def("unmute_ha_alerts", "Unmute Home Alerts", .homeAssistant,
            "Resume Home Assistant camera and motion alerts.", .low, [
            ("unmute home alerts",          .exact),
            ("unmute doorbell alerts",      .exact),
            ("unmute motion alerts",        .exact),
            ("unmute camera alerts",        .exact),
            ("resume home alerts",          .exact),
            ("enable motion alerts",        .exact),
        ]),

        def("show_ha_diagnostics", "HA Diagnostics", .homeAssistant,
            "Open the Home Assistant integration diagnostics overlay.", .low, [
            ("home assistant diagnostics",  .exact),
            ("ha diagnostics",              .exact),
            ("camera diagnostics",          .exact),
            ("home integration status",     .exact),
        ]),
    ] }

    // MARK: - GitHub

    static var github: [CommandDefinition] { [
        def("show_github_overlay", "Show GitHub", .github,
            "Opens the GitHub notifications overlay.", .low, [
            ("show github",                         .startsWith),
            ("open github",                         .startsWith),
        ]),
        def("check_github", "Check GitHub", .github,
            "Speaks a summary of GitHub notifications.", .low, [
            ("any new github",                      .contains),
            ("github notifications",                .contains),
            ("any review requests",                 .contains),
            ("new reviews",                         .contains),
        ]),
        // Intelligence
        def("github_dashboard", "GitHub Dashboard", .github,
            "Opens the GitHub intelligence dashboard.", .medium, [
            ("github dashboard",                    .contains),
            ("show github dashboard",               .contains),
            ("github panel",                        .contains),
        ]),
        def("github_list_prs", "Check PRs", .github,
            "Lists open pull requests.", .medium, [
            ("open prs",                            .exact),
            ("check prs",                           .exact),
            ("open pull requests",                  .contains),
            ("any prs",                             .exact),
            ("show prs",                            .exact),
            ("list pull requests",                  .contains),
        ]),
        def("github_review_pr", "Review PR", .github,
            "AI review of the latest open pull request.", .medium, [
            ("review pr",                           .contains),
            ("review the pr",                       .contains),
            ("review latest pr",                    .contains),
            ("review pull request",                 .contains),
            ("look at the pr",                      .contains),
        ]),
        def("github_stale_prs", "Stale PRs", .github,
            "Lists stale open pull requests.", .low, [
            ("stale prs",                           .contains),
            ("old prs",                             .contains),
            ("stale pull requests",                 .contains),
            ("unreviewed prs",                      .contains),
        ]),
        def("github_list_issues", "Check Issues", .github,
            "Lists open issues.", .medium, [
            ("check issues",                        .contains),
            ("open issues",                         .contains),
            ("list issues",                         .contains),
            ("any issues",                          .exact),
            ("show issues",                         .contains),
        ]),
        def("github_stale_issues", "Stale Issues", .github,
            "Lists stale open issues.", .low, [
            ("stale issues",                        .contains),
            ("old issues",                          .contains),
            ("neglected issues",                    .contains),
        ]),
        def("github_create_issue", "Create Issue", .github,
            "Opens a GitHub issue.", .medium, [
            ("open an issue",                       .contains),
            ("create an issue",                     .contains),
            ("file an issue",                       .contains),
            ("create issue",                        .contains),
            ("new issue",                           .contains),
        ]),
        def("github_recent_commits", "Recent Commits", .github,
            "Reads recent commits.", .medium, [
            ("latest commit",                       .contains),
            ("recent commits",                      .contains),
            ("last commit",                         .contains),
            ("recent changes",                      .contains),
            ("what's new in",                       .contains),
        ]),
        def("github_changes_today", "Changes Today", .github,
            "What changed today.", .medium, [
            ("what changed today",                  .exact),
            ("changes today",                       .contains),
            ("today's commits",                     .contains),
            ("commits today",                       .exact),
        ]),
        def("github_check_ci", "Check CI", .github,
            "Checks CI/build status.", .medium, [
            ("failing builds",                      .contains),
            ("build status",                        .contains),
            ("ci status",                           .contains),
            ("any failures",                        .contains),
            ("is ci passing",                       .contains),
            ("failing ci",                          .contains),
        ]),
        def("github_list_repos", "My Repos", .github,
            "Lists your repositories.", .low, [
            ("my repos",                            .exact),
            ("list repos",                          .exact),
            ("show repos",                          .exact),
            ("my repositories",                     .exact),
        ]),
        def("github_active_repos", "Active Repos", .github,
            "Which repos are most active.", .low, [
            ("active repos",                        .contains),
            ("most active repo",                    .contains),
            ("which repo is most active",           .contains),
        ]),
        def("github_neglected_repos", "Neglected Repos", .github,
            "Repos with no recent activity.", .low, [
            ("neglected repos",                     .contains),
            ("stale repos",                         .contains),
            ("repos need attention",                .contains),
            ("what repos need attention",           .contains),
        ]),
        def("github_create_repo", "Create Repo", .github,
            "Creates a new GitHub repository.", .medium, [
            ("create a repo",                       .contains),
            ("make a repo",                         .contains),
            ("new repo",                            .contains),
            ("new repository",                      .contains),
            ("create repository",                   .contains),
            ("start a new project",                 .contains),
            ("start a project",                     .contains),
            ("new project",                         .contains),
        ]),
        def("github_describe_repo", "Describe Repo", .github,
            "Describes a repo's structure and health.", .low, [
            ("describe repo",                       .contains),
            ("explain repo",                        .contains),
            ("repo structure",                      .contains),
        ]),
        def("github_project_status", "Project Status", .github,
            "Roadmap and progress analysis.", .medium, [
            ("project status",                      .contains),
            ("project progress",                    .contains),
            ("how far are we",                      .contains),
            ("what's left",                         .contains),
            ("what's blocking",                     .contains),
            ("roadmap",                             .contains),
            ("milestone progress",                  .contains),
        ]),
        def("github_code_review", "Code Review", .github,
            "AI-powered code review of latest PR.", .medium, [
            ("code review",                         .contains),
            ("review code",                         .contains),
            ("any risky code",                      .contains),
            ("risky files",                         .contains),
        ]),
        def("github_summarise_diff", "Summarise Diff", .github,
            "Summarises the diff between branches.", .low, [
            ("summarise diff",                      .contains),
            ("summarize diff",                      .contains),
            ("diff summary",                        .contains),
            ("what's in this diff",                 .contains),
        ]),
    ] }

    // MARK: - System Toggles (Wi-Fi / Bluetooth)

    static var systemToggles: [CommandDefinition] { [
        def("wifi_on", "Turn Wi-Fi On", .system, "Enables Wi-Fi.", .low, [
            ("turn on wifi",              .exact),
            ("enable wifi",               .exact),
            ("turn on wi-fi",             .exact),
            ("enable wi-fi",              .exact),
            ("wifi on",                   .exact),
            ("wi-fi on",                  .exact),
        ]),
        def("wifi_off", "Turn Wi-Fi Off", .system, "Disables Wi-Fi.", .low, [
            ("turn off wifi",             .exact),
            ("disable wifi",              .exact),
            ("turn off wi-fi",            .exact),
            ("disable wi-fi",             .exact),
            ("wifi off",                  .exact),
            ("wi-fi off",                 .exact),
        ]),
        def("bluetooth_on", "Turn Bluetooth On", .system, "Enables Bluetooth.", .low, [
            ("turn on bluetooth",         .exact),
            ("enable bluetooth",          .exact),
            ("bluetooth on",              .exact),
        ]),
        def("bluetooth_off", "Turn Bluetooth Off", .system, "Disables Bluetooth.", .low, [
            ("turn off bluetooth",        .exact),
            ("disable bluetooth",         .exact),
            ("bluetooth off",             .exact),
        ]),
    ] }

    // MARK: - Timers & Stopwatch

    static var timers: [CommandDefinition] { [
        def("set_timer", "Set Timer", .system, "Sets a countdown timer.", .low, [
            ("set a timer",         .contains),
            ("set timer",           .contains),
            ("start a timer",       .contains),
            ("timer for",           .contains),
            ("set me a timer",      .contains),
            ("5 minute timer",      .contains),
            ("10 minute timer",     .contains),
            ("30 minute timer",     .contains),
            ("1 hour timer",        .contains),
        ]),
        def("cancel_timer", "Cancel Timer", .system, "Cancels a running timer.", .low, [
            ("cancel timer",        .contains),
            ("cancel the timer",    .contains),
            ("stop the timer",      .exact),
            ("cancel all timers",   .exact),
        ]),
        def("timer_status", "Timer Status", .system, "How much time is left on the timer.", .low, [
            ("how long on the timer",  .contains),
            ("time remaining",         .exact),
            ("timer status",           .exact),
            ("time left",              .exact),
            ("how much time left",     .exact),
        ]),
        def("start_stopwatch", "Start Stopwatch", .system, "Starts the stopwatch.", .low, [
            ("start stopwatch",        .exact),
            ("start the stopwatch",    .exact),
            ("start a stopwatch",      .exact),
            ("stopwatch start",        .exact),
        ]),
        def("stop_stopwatch", "Stop Stopwatch", .system, "Stops the stopwatch.", .low, [
            ("stop stopwatch",         .exact),
            ("stop the stopwatch",     .exact),
            ("pause stopwatch",        .exact),
        ]),
        def("stopwatch_status", "Stopwatch Elapsed", .system, "How long the stopwatch has run.", .low, [
            ("stopwatch status",       .exact),
            ("how long has it been",   .exact),
            ("stopwatch time",         .exact),
            ("stopwatch elapsed",      .exact),
        ]),
    ] }

    // MARK: - Clipboard

    static var clipboard: [CommandDefinition] { [
        def("clipboard_read", "Read Clipboard", .system, "Reads clipboard contents aloud.", .low, [
            ("what's in my clipboard",     .exact),
            ("what is in my clipboard",    .exact),
            ("what did i copy",            .exact),
            ("read clipboard",             .exact),
            ("clipboard contents",         .exact),
            ("show clipboard",             .exact),
        ]),
        def("clipboard_copy", "Copy Last Response", .system, "Copies last Jarvis response to clipboard.", .low, [
            ("copy that",                  .exact),
            ("copy your last response",    .exact),
            ("copy what you said",         .contains),
            ("copy that to clipboard",     .exact),
        ]),
    ] }

    // MARK: - Spotify / Music

    static var spotify: [CommandDefinition] { [
        def("spotify_play", "Play Music", .music,
            "Play music or a specific track/artist/playlist on Spotify.", .low, [
            ("play music",                  .exact),
            ("play some music",             .exact),
            ("play spotify",                .exact),
            ("start music",                 .exact),
            ("start spotify",               .exact),
        ]),
        def("spotify_pause", "Pause Music", .music,
            "Pause Spotify playback.", .low, [
            ("pause music",                 .exact),
            ("pause spotify",               .exact),
            ("stop music",                  .exact),
            ("stop the music",              .exact),
            ("stop playing",                .exact),
            ("stop spotify",                .exact),
        ]),
        def("spotify_next", "Next Track", .music,
            "Skip to the next track.", .low, [
            ("next song",                   .exact),
            ("next track",                  .exact),
            ("skip song",                   .exact),
            ("skip track",                  .exact),
            ("skip this song",              .exact),
        ]),
        def("spotify_previous", "Previous Track", .music,
            "Go back to the previous track.", .low, [
            ("previous song",               .exact),
            ("previous track",              .exact),
            ("last song",                   .exact),
            ("go back",                     .exact),
        ]),
        def("spotify_status", "What's Playing", .music,
            "Asks Spotify what is currently playing.", .low, [
            ("what's playing",              .exact),
            ("what is playing",             .exact),
            ("what song is this",           .exact),
            ("current song",                .exact),
            ("current track",               .exact),
            ("what are you playing",        .exact),
            ("whats playing",               .exact),
        ]),
        def("spotify_shuffle_on", "Shuffle On", .music,
            "Turns Spotify shuffle on.", .low, [
            ("shuffle on",                  .exact),
            ("turn on shuffle",             .exact),
            ("enable shuffle",              .exact),
        ]),
        def("spotify_shuffle_off", "Shuffle Off", .music,
            "Turns Spotify shuffle off.", .low, [
            ("shuffle off",                 .exact),
            ("turn off shuffle",            .exact),
            ("disable shuffle",             .exact),
        ]),
    ] }

    // MARK: - Shopify

    static var shopify: [CommandDefinition] { [
        def("show_shopify", "Show Shopify", .shopify,
            "Opens the Shopify dashboard overlay.", .low, [
            ("show shopify",           .exact),
            ("open shopify",           .exact),
            ("shopify dashboard",      .contains),
            ("shopify overlay",        .contains),
        ]),
        def("shopify_orders", "New Orders", .shopify,
            "Speaks a summary of today's new orders.", .low, [
            ("any new orders",         .exact),
            ("new orders",             .exact),
            ("shopify orders",         .contains),
            ("my orders",              .exact),
            ("orders today",           .exact),
            ("today's orders",         .exact),
            ("todays orders",          .exact),
            ("total orders",           .exact),
            ("how many orders",        .startsWith),
            ("how many orders today",  .exact),
            ("orders do i have",       .contains),
        ]),
        def("shopify_revenue", "Today's Revenue", .shopify,
            "Speaks today's revenue total.", .low, [
            ("today's revenue",        .exact),
            ("todays revenue",         .exact),
            ("what's my revenue",      .contains),
            ("how much have i made",   .contains),
            ("how much did i make",    .exact),
            ("how much money today",   .exact),
            ("revenue today",          .exact),
            ("how much revenue",       .contains),
            ("sales today",            .exact),
            ("today's sales",          .exact),
        ]),
        def("shopify_fulfilment", "Fulfilment Queue", .shopify,
            "Lists orders needing fulfilment.", .low, [
            ("what needs fulfilling",  .exact),
            ("fulfilment queue",       .exact),
            ("fulfillment queue",      .exact),
            ("orders to fulfil",       .contains),
            ("orders to fulfill",      .contains),
        ]),
    ] }

    // MARK: - Builder helper

    private static func def(
        _ id: String,
        _ displayName: String,
        _ category: CommandCategory,
        _ description: String,
        _ safetyLevel: SafetyLevel,
        _ phraseSpecs: [(String, PhraseMatchType, Int)]
    ) -> CommandDefinition {
        var d = CommandDefinition(
            id: id,
            displayName: displayName,
            category: category,
            description: description,
            phrases: [],
            enabled: true,
            safetyLevel: safetyLevel
        )
        for (phrase, matchType, priority) in phraseSpecs {
            d.addPhrase(phrase, matchType: matchType, priority: priority)
        }
        return d
    }

    // MARK: - Obsidian

    static var obsidian: [CommandDefinition] { [

        def("show_obsidian", "Open Obsidian", .ui,
            "Open the Obsidian vault browser overlay.", .low, [
            ("open obsidian",               .exact),
            ("show obsidian",               .exact),
            ("obsidian overlay",            .exact),
            ("my vault",                    .exact),
            ("open my vault",               .exact),
            ("show my vault",               .exact),
        ]),

        def("search_obsidian", "Search Obsidian", .ui,
            "Search the Obsidian vault for notes matching a query.", .low, [
            ("search obsidian",             .exact),
            ("search my vault",             .exact),
            ("search my notes",             .exact),
            ("find in obsidian",            .exact),
            ("obsidian search",             .exact),
            ("find my notes about",         .startsWith),
            ("search notes for",            .startsWith),
        ]),

        def("open_obsidian_note", "Open Note", .ui,
            "Find and display a specific note by name.", .low, [
            ("open my note about",          .startsWith),
            ("open note",                   .startsWith),
            ("show my note about",          .startsWith),
            ("show note",                   .startsWith),
            ("open my note",                .startsWith),
        ]),

        def("read_obsidian_note", "Read Note Aloud", .ui,
            "Read a note aloud by searching the vault.", .low, [
            ("read my note about",          .startsWith),
            ("read note",                   .startsWith),
            ("read my notes on",            .startsWith),
        ]),

        def("create_obsidian_note", "Create Note", .ui,
            "Create a new note in the Obsidian vault.", .low, [
            ("create a note",               .startsWith),
            ("new note",                    .startsWith),
            ("make a note",                 .startsWith),
            ("create note",                 .startsWith),
            ("add a note called",           .startsWith),
        ]),

        def("append_obsidian_note", "Append to Note", .ui,
            "Append text to an existing note in the vault.", .low, [
            ("add to my note",              .startsWith),
            ("append to my note",           .startsWith),
            ("update my note",              .startsWith),
            ("add to my notes on",          .startsWith),
        ]),

        def("recent_obsidian_notes", "Recent Notes", .ui,
            "Show recently modified notes from the vault.", .low, [
            ("recent notes",                .exact),
            ("my recent notes",             .exact),
            ("what notes have i changed",   .exact),
            ("recently modified notes",     .exact),
            ("latest obsidian notes",       .exact),
        ]),

        def("what_do_i_know_about", "What Do I Know About", .ui,
            "Search the Obsidian vault and answer using your notes as context.", .low, [
            ("what do i know about",        .startsWith),
            ("what have i written about",   .startsWith),
            ("what's in my notes about",    .startsWith),
            ("check my notes for",          .startsWith),
            ("look up in my vault",         .startsWith),
        ]),
    ] }

    // MARK: - Mobile / Android Bridge

    static var mobile: [CommandDefinition] { [

        def("show_android", "Android Bridge Panel", .ui,
            "Show the Android phone connection status and diagnostics panel.", .low, [
            ("show android",                .exact),
            ("open android",                .exact),
            ("android panel",               .exact),
            ("android overlay",             .exact),
            ("android dashboard",           .exact),
            ("phone bridge",                .exact),
            ("show phone status",           .exact),
        ]),

        def("show_help", "Show Help / Living Documentation", .ui,
            "Open the Jarvis help overlay and speak a short summary. Data-driven — sections reflect the actual enabled features at the time you ask.",
            .low, [
            ("show help",                   .exact),
            ("help me understand",          .exact),
            ("what can you do",             .exact),
            ("what can you do for me",      .exact),
            ("teach me jarvis",             .exact),
            ("teach me how to use you",     .exact),
            ("open help",                   .exact),
            ("jarvis help",                 .exact),
        ]),

        def("android_status", "Android Bridge Status", .ui,
            "Report the Android bridge connection status, battery, and device name.", .low, [
            ("android status",              .exact),
            ("bridge status",               .exact),
            ("phone status",                .exact),
            ("is my phone connected",       .exact),
            ("phone connection status",     .exact),
            ("is android connected",        .exact),
            ("check android connection",    .exact),
            ("is my phone online",          .exact),
            ("is the phone online",         .exact),
        ]),

        def("phone_battery", "Phone Battery", .ui,
            "Report the connected Android phone's battery level and charging state from the most recent heartbeat (no LLM, no network).",
            .low, [
            ("what is my phone battery",         .contains),
            ("what's my phone battery",          .contains),
            ("what is the battery on my phone",  .contains),
            ("what's the battery on my phone",   .contains),
            ("how much battery has my phone got", .contains),
            ("how much battery does my phone have", .contains),
            ("phone battery",                    .exact),
            ("phone battery level",              .exact),
            ("is my phone charging",             .contains),
            ("is the phone charging",            .contains),
        ]),

        def("call_contact", "Call Contact", .system,
            "Place a phone call via the Android phone.", .low, [
            ("call",                        .startsWith),
            ("ring",                        .startsWith),
            ("dial",                        .startsWith),
            ("phone",                       .startsWith),
        ]),

        def("whatsapp_voice_call", "WhatsApp Voice Call", .system,
            "Place a WhatsApp voice call to a contact through the connected Android phone. Free-form contact name parsed by NLP.",
            .low, [
            // Routed via IntentRouter substring path, not these alone — but
            // we still surface them in the phrase library so users can edit.
            ("call * on whatsapp",          .contains),
            ("phone * on whatsapp",         .contains),
            ("ring * on whatsapp",          .contains),
            ("whatsapp call",               .startsWith),
        ]),

        def("whatsapp_video_call", "WhatsApp Video Call", .system,
            "Place a WhatsApp video call to a contact through the connected Android phone.",
            .low, [
            ("video call * on whatsapp",    .contains),
            ("whatsapp video call",         .startsWith),
            ("video whatsapp",              .startsWith),
        ]),

        def("send_sms", "Send SMS", .system,
            "Send a text message via the Android phone.", .low, [
            ("text",                        .startsWith),
            ("send a text to",              .startsWith),
            ("send sms to",                 .startsWith),
            ("send an sms to",              .startsWith),
            ("text message to",             .startsWith),
        ]),

        def("send_whatsapp", "Send WhatsApp", .system,
            "Send a WhatsApp message via the Android phone.", .low, [
            ("whatsapp",                    .startsWith),
            ("send a whatsapp to",          .startsWith),
            ("send whatsapp to",            .startsWith),
            ("whatsapp message to",         .startsWith),
        ]),

        def("find_contact", "Find Contact", .system,
            "Search for a contact on the Android phone.", .low, [
            ("find contact",                .startsWith),
            ("search contacts",             .startsWith),
            ("look up contact",             .startsWith),
            ("search for contact",          .startsWith),
        ]),

        def("ring_phone", "Ring My Phone", .system,
            "Make the Android phone ring to locate it.", .low, [
            ("ring my phone",               .exact),
            ("ring phone",                  .exact),
            ("make my phone ring",          .exact),
            ("make it ring",                .exact),
            ("ring it",                     .exact),
        ]),

        def("phone_location", "Find My Phone", .system,
            "Report the current location of the Android phone.", .low, [
            ("find my phone",               .exact),
            ("where is my phone",           .exact),
            ("locate my phone",             .exact),
            ("track my phone",              .exact),
            ("phone location",              .exact),
            ("where's my phone",            .exact),
        ]),

        def("start_navigation", "Start Navigation", .system,
            "Start turn-by-turn navigation on the Android phone.", .low, [
            ("navigate to",                 .startsWith),
            ("directions to",               .startsWith),
            ("take me to",                  .startsWith),
            ("get me to",                   .startsWith),
            ("how do i get to",             .startsWith),
        ]),

        def("read_notifications", "Read Phone Notifications", .system,
            "Read out unread notifications from the Android phone.", .low, [
            ("read my notifications",       .exact),
            ("read notifications",          .exact),
            ("what are my notifications",   .exact),
            ("check my phone notifications",.exact),
            ("what are my phone notifications", .exact),
            ("show my notifications from my phone", .exact),
            ("latest notification",         .exact),
            ("recent notifications",        .exact),
        ]),

        def("query_notification", "Check App Notifications", .system,
            "Check notifications or messages from a specific person or app.", .low, [
            ("notifications from",          .startsWith),
            ("notification from",           .startsWith),
            ("what did",                    .startsWith),
            ("did i reply to",              .startsWith),
            ("have i replied to",           .startsWith),
            ("any messages from",           .startsWith),
            ("messages from",               .startsWith),
            ("message from",                .startsWith),
            ("did they message me",         .contains),
            ("did she message me",          .contains),
            ("did he message me",           .contains),
        ]),

        def("capture_phone_camera", "Phone Camera", .system,
            "Capture and describe what the Android phone's camera sees.", .low, [
            ("phone camera",                .exact),
            ("camera on my phone",          .exact),
            ("capture from phone",          .exact),
            ("take photo on phone",         .exact),
            ("what does my phone see",      .exact),
        ]),

        // ── Android phone event follow-up actions ─────────────────────────
        def("call_back_last_caller", "Call Back", .system,
            "Call back the most recent missed or incoming caller.", .medium, [
            ("call him back",               .exact),
            ("call her back",               .exact),
            ("call them back",              .exact),
            ("call back",                   .exact),
            ("return the call",             .exact),
            ("ring them back",              .exact),
            ("ring him back",               .exact),
            ("ring her back",               .exact),
            ("call that person back",       .exact),
            ("phone them back",             .exact),
        ]),

        def("reply_to_last_sender", "Reply to Last Message", .system,
            "Reply to the most recent SMS or WhatsApp sender.", .medium, [
            ("reply saying",                .startsWith),
            ("reply with",                  .startsWith),
            ("send a reply",                .startsWith),
            ("message them back saying",    .startsWith),
            ("reply",                       .exact),
            ("reply to that",               .exact),
            ("send a reply to that",        .exact),
            ("message them back",           .exact),
        ]),

        def("show_latest_android_message", "Show Latest Message", .system,
            "Open the Android overlay and show the latest message.", .low, [
            ("what did they say",           .exact),
            ("what did she say",            .exact),
            ("what did he say",             .exact),
            ("what was the message",        .exact),
            ("show the message",            .exact),
            ("show me the message",         .exact),
            ("show latest message",         .exact),
            ("what did they text",          .exact),
            ("what did they whatsapp",      .exact),
            ("read the message",            .exact),
        ]),

        // ── Phase-1 remote call control ───────────────────────────────────
        def("answer_call", "Answer Call", .system,
            "Answer the incoming call on your Android phone.", .high, [
            ("answer it",                   .exact),
            ("answer the call",             .exact),
            ("pick up",                     .exact),
            ("pick it up",                  .exact),
            ("accept the call",             .exact),
            ("accept it",                   .exact),
            ("answer phone",                .exact),
        ]),

        def("decline_call", "Decline Call", .system,
            "Decline or reject the incoming call on your Android phone.", .high, [
            ("decline it",                  .exact),
            ("decline the call",            .exact),
            ("reject it",                   .exact),
            ("reject the call",             .exact),
            ("ignore it",                   .exact),
            ("ignore the call",             .exact),
            ("send to voicemail",           .exact),
            ("don't answer",                .exact),
        ]),

        def("hang_up_call", "Hang Up", .system,
            "End the active call on your Android phone.", .high, [
            ("hang up",                     .exact),
            ("end the call",                .exact),
            ("hang up the call",            .exact),
            ("end call",                    .exact),
            ("disconnect",                  .exact),
            ("hang up now",                 .exact),
        ]),

        def("speaker_on", "Speakerphone On", .system,
            "Switch the active Android call to speakerphone.", .medium, [
            ("put it on speaker",           .exact),
            ("speaker on",                  .exact),
            ("speakerphone on",             .exact),
            ("turn on speaker",             .exact),
            ("put on speakerphone",         .exact),
            ("switch to speaker",           .exact),
        ]),

        def("speaker_off", "Speakerphone Off", .system,
            "Switch the active Android call off speakerphone.", .medium, [
            ("turn speaker off",            .exact),
            ("speaker off",                 .exact),
            ("speakerphone off",            .exact),
            ("turn off speaker",            .exact),
            ("take off speakerphone",       .exact),
            ("switch off speaker",          .exact),
        ]),
    ] }

    // Overload without explicit priority (defaults to 0)
    private static func def(
        _ id: String,
        _ displayName: String,
        _ category: CommandCategory,
        _ description: String,
        _ safetyLevel: SafetyLevel,
        _ phraseSpecs: [(String, PhraseMatchType)]
    ) -> CommandDefinition {
        let withPriority = phraseSpecs.map { ($0.0, $0.1, 0) }
        return def(id, displayName, category, description, safetyLevel, withPriority)
    }

    // MARK: - Reddit

    /// Voice surface for the Reddit integration.  Subreddit names + free-form
    /// queries are extracted by IntentRouter after the phrase matcher picks
    /// the right command id — the phrases here only have to identify intent.
    static var reddit: [CommandDefinition] { [
        def("reddit_show", "Show Reddit", .reddit,
            "Open the Reddit overlay with the configured subreddits' latest posts.",
            .low, [
            ("show reddit",                     .exact),
            ("open reddit",                     .exact),
            ("show my reddits",                 .exact),
            ("reddit",                          .exact),
            ("show reddit posts",               .exact),
            ("open the reddit panel",           .exact),
            ("reddit panel",                    .exact),
            ("reddit overlay",                  .exact),
        ]),

        def("reddit_show_top", "Show Top Reddit Posts", .reddit,
            "Open the Reddit overlay ranked by score across every enabled subreddit.",
            .low, [
            ("show top reddits",                .exact),
            ("show top reddit",                 .exact),
            ("show top reddit posts",           .exact),
            ("top reddit posts",                .exact),
            ("top posts on reddit",             .exact),
            ("what is hot on reddit",           .exact),
            ("what is trending on reddit",      .exact),
        ]),

        def("reddit_show_subreddit", "Show a Subreddit", .reddit,
            "Open the Reddit overlay scoped to one subreddit (matched against the source list).",
            .low, [
            // The IntentRouter extracts the subreddit name from anywhere
            // after the prefix; .prefix catches the natural variations
            // ("show r/technology", "show technology subreddit", etc.).
            ("show r ",                          .startsWith),
            ("show the r ",                      .startsWith),
            ("open r ",                          .startsWith),
            ("show reddit r ",                   .startsWith),
            ("show subreddit ",                  .startsWith),
            ("open subreddit ",                  .startsWith),
            ("show me subreddit ",               .startsWith),
            ("open the subreddit ",              .startsWith),
            // Natural-language variants ("show technology subreddit",
            // "open LocalLLaMA") are caught by IntentRouter substring
            // routing in route(_:), which validates the name against the
            // configured source list before firing the intent.
        ]),

        def("reddit_query", "Search Reddit", .reddit,
            "Search every enabled subreddit for a phrase and show the merged results.",
            .low, [
            ("search reddit for ",              .startsWith),
            ("search my reddits for ",          .startsWith),
            ("what is reddit saying about ",    .startsWith),
            ("what are people saying about ",   .startsWith),
            ("what does reddit think about ",   .startsWith),
            ("what does reddit say about ",     .startsWith),
            ("reddit opinion on ",              .startsWith),
            ("reddit thoughts on ",             .startsWith),
        ]),

        def("reddit_summarise_post", "Summarise Reddit Post", .reddit,
            "Use the LLM to summarise the body of the currently-open Reddit post.",
            .low, [
            ("summarise this post",             .exact),
            ("summarize this post",             .exact),
            ("summarise the post",              .exact),
            ("summarize the post",              .exact),
            ("summarise this reddit post",      .exact),
            ("summarize this reddit post",      .exact),
            ("what is this post about",         .exact),
            ("tldr this post",                  .exact),
        ]),

        def("reddit_summarise_comments", "Summarise Reddit Comments", .reddit,
            "Use the LLM to summarise the comment thread of the currently-open Reddit post.",
            .low, [
            ("summarise the comments",          .exact),
            ("summarize the comments",          .exact),
            ("what are the comments saying",    .exact),
            ("what do the comments say",        .exact),
            ("summarise reddit comments",       .exact),
            ("summarize reddit comments",       .exact),
            ("tldr the comments",               .exact),
        ]),

        def("reddit_open_first", "Open First Reddit Post", .reddit,
            "Open the first post in the current Reddit list.",
            .low, [
            ("open first reddit post",          .exact),
            ("open the first reddit post",      .exact),
            ("open the first one",              .exact),
            ("open first one",                  .exact),
            ("show first reddit post",          .exact),
        ]),

        def("reddit_open_in_browser", "Open Reddit Post in Browser", .reddit,
            "Open the active Reddit post's outbound link in the default browser.",
            .low, [
            ("open in browser",                 .exact),
            ("open this in browser",            .exact),
            ("open the link in safari",         .exact),
            ("open in safari",                  .exact),
            ("show me in browser",              .exact),
        ]),

        def("reddit_show_comments", "Show Reddit Comments", .reddit,
            "Load and display the comment thread for the active Reddit post.",
            .low, [
            ("show comments",                   .exact),
            ("show the comments",               .exact),
            ("open comments",                   .exact),
            ("load comments",                   .exact),
            ("show reddit comments",            .exact),
        ]),

        def("reddit_save_post", "Save Reddit Post", .reddit,
            "Save the active Reddit post so it survives the cache rotation.",
            .low, [
            ("save that",                       .exact),
            ("save this post",                  .exact),
            ("save this reddit post",           .exact),
            ("save reddit post",                .exact),
            ("bookmark this post",              .exact),
        ]),

        def("reddit_refresh", "Refresh Reddit", .reddit,
            "Re-poll every enabled subreddit for fresh posts.",
            .low, [
            ("refresh reddit",                  .exact),
            ("update reddit",                   .exact),
            ("reload reddit",                   .exact),
            ("get new reddit posts",            .exact),
        ]),
    ] }

    // MARK: - Apple Notes (Sprint X)

    static var appleNotes: [CommandDefinition] { [
        def("open_notes", "Open Notes", .memory,
            "Bring Apple Notes to the foreground.", .low, [
            ("open notes",           .exact),
            ("show notes",           .exact),
            ("open apple notes",     .exact),
            ("show apple notes",     .exact),
            ("notes app",            .exact),
        ]),
        def("create_note", "Create Note", .memory,
            "Create a new note in Apple Notes.", .medium, [
            ("create a note",        .startsWith),
            ("create note",          .startsWith),
            ("new note",             .startsWith),
            ("add a note",           .startsWith),
            ("save a note",          .startsWith),
            ("make a note",          .startsWith),
            ("note that",            .startsWith),
            ("take a note",          .startsWith),
        ]),
        def("append_note", "Append to Note", .memory,
            "Append text to an existing note in Apple Notes.", .medium, [
            ("append to note",       .startsWith),
            ("add to note",          .startsWith),
            ("add to my note",       .startsWith),
            ("append to my note",    .startsWith),
            ("update note",          .startsWith),
        ]),
        def("search_notes", "Search Notes", .memory,
            "Search Apple Notes for matching notes.", .medium, [
            ("search notes",         .startsWith),
            ("search my notes",      .startsWith),
            ("find note",            .startsWith),
            ("find in notes",        .startsWith),
            ("look up notes",        .startsWith),
        ]),
    ] }

    // MARK: - Email / Apple Mail (Sprint AA)

    static var email: [CommandDefinition] { [
        def("check_email", "Check Email", .email,
            "Check your email and read unread count.", .medium, [
            ("check email",          .exact),
            ("check my email",       .exact),
            ("any new emails",       .exact),
            ("new emails",           .exact),
            ("emails",               .exact),
            ("open mail",            .exact),
        ]),
        def("unread_email", "Read Unread", .email,
            "List unread emails from your inbox.", .medium, [
            ("unread emails",        .exact),
            ("read unread",          .exact),
            ("what emails do i have",.exact),
            ("what's in my inbox",   .exact),
            ("whats in my inbox",    .exact),
            ("inbox",                .exact),
        ]),
        def("read_latest_email", "Read Latest Email", .email,
            "Read the most recent email.", .medium, [
            ("read latest email",    .exact),
            ("latest email",         .exact),
            ("most recent email",    .exact),
            ("last email",           .exact),
            ("read my email",        .exact),
        ]),
        def("search_email", "Search Email", .email,
            "Search emails for a keyword or sender.", .medium, [
            ("search email",         .startsWith),
            ("search emails",        .startsWith),
            ("search my email",      .startsWith),
            ("find email",           .startsWith),
            ("find emails",          .startsWith),
            ("emails from",          .startsWith),
            ("emails about",         .startsWith),
        ]),
        def("summarise_email", "Summarise Email", .email,
            "Summarise your unread emails.", .medium, [
            ("summarise emails",     .exact),
            ("summarize emails",     .exact),
            ("email summary",        .exact),
            ("email digest",         .exact),
            ("what emails are unread",.exact),
        ]),
        def("draft_email", "Draft Email", .email,
            "Create a new email draft (does not send automatically).", .high, [
            ("draft an email",       .startsWith),
            ("draft email",          .startsWith),
            ("compose an email",     .startsWith),
            ("compose email",        .startsWith),
            ("write an email",       .startsWith),
            ("write email",          .startsWith),
            ("new email",            .startsWith),
            ("email to",             .startsWith),
        ]),
        def("reply_email", "Reply to Email", .email,
            "Create a reply draft to an email (does not send automatically).", .high, [
            ("reply to email",       .startsWith),
            ("reply to",             .startsWith),
            ("reply email",          .startsWith),
            ("send reply to",        .startsWith),
        ]),
        def("show_email", "Open Mail", .email,
            "Bring Apple Mail to the foreground.", .low, [
            ("show email",           .exact),
            ("open email",           .exact),
            ("open apple mail",      .exact),
            ("show apple mail",      .exact),
            ("mail app",             .exact),
        ]),
        def("important_email", "Important Email", .email,
            "Show emails flagged as urgent or important.", .medium, [
            ("important emails",     .exact),
            ("urgent emails",        .exact),
            ("priority emails",      .exact),
            ("any urgent emails",    .exact),
            ("vip emails",           .exact),
        ]),
    ] }

    // MARK: - Conversational Jarvis (Sprint K)

    static var conversational: [CommandDefinition] { [

        def("log_progress_note", "Log Progress Note", .memory,
            "Save a progress update to project memory and Obsidian.", .medium, [
            ("log that as done",                .exact),
            ("log that",                        .exact),
            ("log this as done",                .exact),
            ("log this",                        .exact),
            ("mark that as done",               .exact),
            ("mark this as done",               .exact),
            ("mark that complete",              .exact),
            ("save that to the roadmap",        .exact),
            ("add that to the roadmap",         .exact),
        ]),

        def("save_to_project_memory", "Save to Project Memory", .memory,
            "Save the last conversational context to project memory.", .medium, [
            ("save that",                       .exact),
            ("save this",                       .exact),
            ("add to project memory",           .exact),
            ("remember that for the project",   .exact),
            ("save to project",                 .exact),
            ("log that to memory",              .exact),
        ]),

        def("query_project_memory", "Query Project Memory", .memory,
            "Search project memory for information.", .medium, [
            ("what have i built",               .exact),
            ("what did i build",                .startsWith),
            ("what have we built",              .exact),
            ("what's been done",                .exact),
            ("what's missing",                  .exact),
            ("what is missing",                 .exact),
            ("what's left to build",            .exact),
            ("what should i build next",        .exact),
            ("project status",                  .exact),
            ("show project status",             .exact),
        ]),

        def("show_today_jarvis_log", "Show Today's Jarvis Log", .memory,
            "Open today's Jarvis daily note in Obsidian.", .low, [
            ("show today jarvis log",           .exact),
            ("show jarvis log",                 .exact),
            ("open jarvis log",                 .exact),
            ("today log",                       .exact),
            ("show daily log",                  .exact),
        ]),

        def("pause_memory_logging", "Pause Memory Logging", .memory,
            "Pause automatic memory extraction for this session.", .low, [
            ("stop logging",                    .exact),
            ("pause logging",                   .exact),
            ("do not log",                      .exact),
            ("pause memory",                    .exact),
            ("stop saving",                     .exact),
        ]),

        def("resume_memory_logging", "Resume Memory Logging", .memory,
            "Resume automatic memory extraction.", .low, [
            ("start logging",                   .exact),
            ("start logging again",             .exact),
            ("resume logging",                  .exact),
            ("resume memory",                   .exact),
            ("start saving again",              .exact),
        ]),

        def("do_not_save_this", "Do Not Save This", .memory,
            "Mark the current conversation turn as ephemeral — do not save to memory.", .low, [
            ("do not save this",                .exact),
            ("don't save this",                 .exact),
            ("off the record",                  .exact),
            ("this is private",                 .exact),
            ("keep this private",               .exact),
        ]),

        def("show_routing_diagnostics", "Show Routing Diagnostics", .system,
            "Show ConversationRouter classification debug info.", .low, [
            ("show routing diagnostics",        .exact),
            ("routing diagnostics",             .exact),
            ("conversation diagnostics",        .exact),
            ("show route debug",                .exact),
        ]),

        def("play_ping_pong", "Play Ping Pong", .system,
            "Open the hand-tracked ping pong game.", .medium, [
            ("play ping pong",              .exact),
            ("ping pong",                   .exact),
            ("pong",                        .exact),
            ("play pong",                   .exact),
            ("start ping pong",             .exact),
            ("open ping pong",              .exact),
            ("ping pong game",              .exact),
        ]),

        def("show_brain_overlay", "Show Brain", .system,
            "Open the Brain long-term memory and episode browser.", .medium, [
            ("show brain",                      .exact),
            ("open brain",                      .exact),
            ("brain overlay",                   .exact),
            ("brain memory",                    .exact),
            ("show memory brain",               .exact),
        ]),

        def("brain_summary_today", "Brain Summary Today", .system,
            "Speak a digest of today's Brain episodes and memories.", .medium, [
            ("brain summary",                   .exact),
            ("what do you remember today",      .exact),
            ("today's brain summary",           .exact),
            ("brain today",                     .exact),
        ]),

        def("brain_summary_week", "Brain Summary Week", .system,
            "Speak a weekly summary of Brain memories and episodes.", .low, [
            ("brain week",                      .exact),
            ("brain weekly summary",            .exact),
            ("what have you learned this week", .exact),
            ("weekly brain summary",            .exact),
        ]),

    ] }

    // MARK: - Surveillance / POI Vision (Sprint L)

    static var surveillance: [CommandDefinition] { [

        def("show_surveillance_mode", "Show Surveillance Mode", .system,
            "Open the POI surveillance HUD overlay.", .high, [
            ("show surveillance",               .exact),
            ("show cameras",                    .exact),
            ("surveillance mode",               .exact),
            ("open surveillance",               .exact),
            ("show cctv",                       .exact),
            ("show camera feeds",               .exact),
            ("camera dashboard",                .exact),
            ("show the machine",                .exact),
        ]),

        def("hide_surveillance_mode", "Hide Surveillance", .system,
            "Close the surveillance HUD.", .medium, [
            ("hide surveillance",               .exact),
            ("close cameras",                   .exact),
            ("exit surveillance",               .exact),
            ("close surveillance",              .exact),
        ]),

        def("start_surveillance", "Start Surveillance", .system,
            "Activate the visual detection pipeline.", .high, [
            ("start surveillance",              .exact),
            ("activate surveillance",           .exact),
            ("start monitoring",                .exact),
            ("enable surveillance",             .exact),
            ("activate cameras",                .exact),
        ]),

        def("stop_surveillance", "Stop Surveillance", .system,
            "Deactivate visual detection.", .medium, [
            ("stop surveillance",               .exact),
            ("disable surveillance",            .exact),
            ("stop monitoring cameras",         .exact),
            ("deactivate surveillance",         .exact),
        ]),

        def("describe_visual_scene", "Describe the Scene", .camera,
            "Spoken description of what all cameras currently see.", .high, [
            ("what do you see",                 .exact),
            ("describe the scene",              .exact),
            ("what can you see",                .exact),
            ("describe what you see",           .exact),
            ("tell me what you see",            .exact),
            ("scene description",               .exact),
        ]),

        def("who_is_at_location", "Who Is There", .camera,
            "Report who or what is detected at a named location.", .high, [
            ("who is at the door",              .exact),
            ("who's at the door",               .exact),
            ("anyone at the door",              .exact),
            ("what's at the front door",        .exact),
            ("who is outside",                  .exact),
            ("who's outside",                   .exact),
            ("anyone outside",                  .exact),
        ]),

        def("any_people_detected", "Any People Detected", .camera,
            "Check if any people are currently visible.", .high, [
            ("any people outside",              .exact),
            ("any people detected",             .exact),
            ("is anyone there",                 .exact),
            ("see any people",                  .exact),
            ("detect any humans",               .exact),
            ("spot anyone",                     .exact),
        ]),

        def("focus_camera", "Focus Camera", .camera,
            "Show a specific named camera in focus view.", .medium, [
            // Named-location phrases (front door, driveway, etc.) are handled by
            // show_ha_camera → homeShowCameraOverlay, not here.
            ("focus on front door",             .startsWith),
            ("show camera",                     .startsWith),
            ("focus camera",                    .startsWith),
        ]),

        def("last_motion_event", "Last Motion Event", .camera,
            "Report the most recent motion detection event.", .medium, [
            ("what moved",                      .exact),
            ("last motion event",               .exact),
            ("what triggered motion",           .exact),
            ("latest motion",                   .exact),
            ("what set off the alarm",          .exact),
            ("any recent motion",               .exact),
        ]),

        def("show_threat_status", "Threat Status", .camera,
            "Report current threat level across all camera feeds.", .medium, [
            ("show threat status",              .exact),
            ("threat report",                   .exact),
            ("threat level",                    .exact),
            ("security status",                 .exact),
            ("are we safe",                     .exact),
            ("anything suspicious",             .exact),
        ]),

        def("activate_threat_tracking", "Activate Threat Tracking", .camera,
            "Increase detection frequency and alert sensitivity.", .high, [
            ("track that",                      .exact),
            ("track that person",               .exact),
            ("activate threat tracking",        .exact),
            ("high alert mode",                 .exact),
            ("watch mode on",                   .exact),
        ]),

    ] }

    // MARK: - Spatial Interaction Phase 1 (Sprint M)

    static var spatial: [CommandDefinition] { [

        def("save_workspace", "Save Workspace", .ui,
            "Save the current widget layout as a named workspace.", .medium, [
            ("save workspace",              .contains),
            ("save this layout",            .exact),
            ("save my layout",              .exact),
            ("create workspace",            .contains),
            ("new workspace",               .exact),
        ]),

        def("restore_workspace", "Restore Workspace", .ui,
            "Restore a previously saved widget workspace by name.", .medium, [
            ("restore workspace",           .contains),
            ("load workspace",              .contains),
            ("open workspace",              .contains),
            ("switch to workspace",         .contains),
        ]),

        def("list_workspaces", "List Workspaces", .ui,
            "Show all saved spatial workspaces.", .low, [
            ("list workspaces",             .exact),
            ("show workspaces",             .exact),
            ("my workspaces",               .exact),
            ("show my layouts",             .exact),
        ]),

        def("move_widget_left", "Move Widget Left", .ui,
            "Move the hovered widget to the left.", .medium, [
            ("move that left",              .exact),
            ("move this left",              .exact),
            ("move it left",                .exact),
            ("shift that left",             .exact),
        ]),

        def("move_widget_right", "Move Widget Right", .ui,
            "Move the hovered widget to the right.", .medium, [
            ("move that right",             .exact),
            ("move this right",             .exact),
            ("move it right",               .exact),
            ("shift that right",            .exact),
        ]),

        def("move_widget_up", "Move Widget Up", .ui,
            "Move the hovered widget upward.", .medium, [
            ("move that up",                .exact),
            ("move this up",                .exact),
            ("move it up",                  .exact),
        ]),

        def("move_widget_down", "Move Widget Down", .ui,
            "Move the hovered widget downward.", .medium, [
            ("move that down",              .exact),
            ("move this down",              .exact),
            ("move it down",                .exact),
        ]),

        def("resize_widget_large", "Enlarge Widget", .ui,
            "Make the hovered widget larger.", .medium, [
            ("make this bigger",            .exact),
            ("make that bigger",            .exact),
            ("make it bigger",              .exact),
            ("expand that",                 .exact),
            ("expand this",                 .exact),
            ("resize larger",               .exact),
            ("make it larger",              .exact),
        ]),

        def("resize_widget_small", "Shrink Widget", .ui,
            "Make the hovered widget smaller.", .medium, [
            ("make this smaller",           .exact),
            ("make that smaller",           .exact),
            ("make it smaller",             .exact),
            ("shrink that",                 .exact),
            ("shrink this",                 .exact),
            ("resize smaller",              .exact),
        ]),

        def("minimize_widget", "Minimize Widget", .ui,
            "Minimize or collapse the hovered widget.", .medium, [
            ("minimize this",               .exact),
            ("minimize that",               .exact),
            ("collapse this",               .exact),
            ("collapse that",               .exact),
            ("minimize widget",             .exact),
        ]),

        def("dock_widget", "Dock Widget", .ui,
            "Dock the hovered widget to a screen edge.", .medium, [
            ("dock this",                   .contains),
            ("dock that",                   .contains),
            ("pin this to the",             .startsWith),
            ("pin that to the",             .startsWith),
        ]),

        def("snap_widget", "Snap Widget", .ui,
            "Snap the hovered widget to a screen zone.", .medium, [
            ("snap this to",                .startsWith),
            ("snap that to",                .startsWith),
            ("snap it to",                  .startsWith),
            ("snap to",                     .startsWith),
        ]),

        def("show_spatial_debug", "Spatial Debug", .ui,
            "Show spatial interaction diagnostic overlay.", .low, [
            ("show spatial debug",          .exact),
            ("spatial diagnostics",         .exact),
            ("spatial debug",               .exact),
            ("gesture debug",               .exact),
        ]),

        def("snap_window_left", "Snap Window Left", .ui,
            "Snap a native macOS window to the left half of the screen.", .medium, [
            ("snap left",                   .contains),
            ("move to left half",           .contains),
            ("snap to left",                .contains),
        ]),

        def("snap_window_right", "Snap Window Right", .ui,
            "Snap a native macOS window to the right half of the screen.", .medium, [
            ("snap right",                  .contains),
            ("move to right half",          .contains),
            ("snap to right",               .contains),
        ]),

        def("tile_windows", "Tile Windows", .ui,
            "Automatically tile all open windows side by side.", .medium, [
            ("tile windows",                .exact),
            ("tile all windows",            .exact),
            ("arrange windows",             .exact),
            ("split my windows",            .exact),
        ]),

        def("focus_window", "Focus Window", .ui,
            "Bring a specific app window to the front.", .medium, [
            ("focus on",                    .startsWith),
            ("switch to",                   .startsWith),
            ("bring up",                    .startsWith),
            ("open app",                    .startsWith),
        ]),

    ] }
}
