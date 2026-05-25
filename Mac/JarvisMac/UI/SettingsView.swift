import SwiftUI

/// Settings window — 9-tab structure replacing the old 19-tab layout.
///
/// Tab map:
///   General     — identity, cameras, performance, web overlays
///   Voice       — speech, wake word, commands (segmented)
///   Conversation — mode/memory, personality, responses (segmented)
///   Models      — providers, vision, intelligence, GitHub intel (segmented)
///   Connections — all Keychain tokens and auth credentials
///   Integrations — HA, calendar, Shopify, Obsidian, Android bridge
///   Gestures    — GesturePreferencesView
///   News & Feeds — news channels/RSS, Reddit (segmented)
///   Developer   — subsystems, logging, Brain API, Training (segmented)
struct SettingsView: View {
    let state: AppState
    let controller: JarvisController

    enum Tab: String, CaseIterable, Identifiable {
        case general, voice, conversation, models, connections,
             integrations, gestures, newsFeeds, devices, developer
        var id: String { rawValue }
    }

    // MARK: - State

    @State private var tab: Tab = .general
    // Voice sub-tabs
    @State private var voiceSubTab: Int = 0       // 0=Speech, 1=Wake Word, 2=Commands
    @State private var commandsSubTab: Int = 0    // 0=Phrase Library, 1=Unmatched
    // Conversation sub-tabs
    @State private var convSubTab: Int = 0        // 0=Mode & Memory, 1=Personality, 2=Responses
    // Models sub-tabs
    @State private var modelsSubTab: Int = 0      // 0=Providers, 1=Vision, 2=Intelligence, 3=GitHub
    // Developer sub-tabs
    @State private var devSubTab: Int = 0         // 0=Subsystems, 1=Logging, 2=Brain API, 3=Training
    // News & Feeds sub-tabs
    @State private var newsFeedsSubTab: Int = 0   // 0=News, 1=Reddit
    // API key drafts (Keychain-backed, not stored in prefs JSON)
    @State private var miniMaxKeyDraft: String = ""
    @State private var miniMaxTestResult: String? = nil
    @State private var miniMaxTestIsError: Bool = false
    @State private var miniMaxCurlCopied: Bool = false
    @State private var localLLMTestResult: String? = nil
    @State private var xaiKeyDraft: String = ""
    @State private var xaiTestResult: String? = nil
    @State private var xaiTestIsError: Bool = false
    @State private var geminiKeyDraft: String = ""
    @State private var geminiTestResult: String? = nil
    @State private var geminiTestIsError: Bool = false
    @State private var isTesting = false
    @State private var githubIssueTokenDraft: String = ""
    @State private var githubIssueTestResult: String? = nil
    @State private var githubIssueTestIsError: Bool = false
    // HA alias sheet
    @State private var showingAddAlias = false
    @State private var newAliasFriendlyName = ""
    @State private var newAliasEntityID = ""
    @State private var revealSecret = false

    // MARK: - Body

    var body: some View {
        TabView(selection: $tab) {
            Group {
                generalTab
                    .tabItem { Label("General",      systemImage: "gearshape") }
                    .tag(Tab.general)
                voiceTab
                    .tabItem { Label("Voice",        systemImage: "waveform") }
                    .tag(Tab.voice)
                conversationTab
                    .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.conversation)
                modelsTab
                    .tabItem { Label("Models",       systemImage: "brain") }
                    .tag(Tab.models)
                connectionsTab
                    .tabItem { Label("Connections",  systemImage: "key") }
                    .tag(Tab.connections)
            }
            Group {
                integrationsTab
                    .tabItem { Label("Integrations", systemImage: "puzzlepiece") }
                    .tag(Tab.integrations)
                GesturePreferencesView(controller: controller)
                    .tabItem { Label("Gestures",     systemImage: "hand.raised") }
                    .tag(Tab.gestures)
                newsFeedsTab
                    .tabItem { Label("News & Feeds", systemImage: "newspaper") }
                    .tag(Tab.newsFeeds)
                devicesTab
                    .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                    .tag(Tab.devices)
                developerTab
                    .tabItem { Label("Developer",    systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.developer)
            }
        }
        .frame(minWidth: 960, idealWidth: 1080, maxWidth: 1600,
               minHeight: 540, idealHeight: 600, maxHeight: 800)
        .padding(.bottom, 8)
    }

    // MARK: - Tab 1: General

    private var generalTab: some View {
        Form {
            Section("You") {
                TextField("Your name (used in greetings)",
                          text: identityOptStringBinding(\.userName))
                TextField("Assistant name (default: Jarvis)",
                          text: identityStringBinding(\.assistantName))
            }

            Section {
                Picker("Preferred camera", selection: cameraBinding) {
                    Text("Auto").tag(String?.none)
                    ForEach(state.availableCameras) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                Picker("Desk Camera", selection: deskCameraBinding) {
                    Text("Not configured").tag(String?.none)
                    ForEach(state.availableCameras) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                Text("The desk camera is used for ambient vision and monitoring.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Cameras", systemImage: "camera")
            }

            Section {
                Toggle("Safe Mode (recommended)", isOn: safeModeBinding)
                Text("Disables blur effects, live video autoplay, and high-frequency Canvas animations. Prevents WindowServer GPU overload on busy displays. Restart Jarvis after changing.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Performance", systemImage: "speedometer")
            }

            Section("Diagnostics") {
                LabeledContent("Safe Mode active") {
                    Text(state.safeMode ? "ON" : "OFF")
                        .foregroundStyle(state.safeMode ? .green : .orange)
                        .monospacedDigit()
                }
                LabeledContent("Open overlays") {
                    Text("\(controller.overlayManager.overlays.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("WKWebView instances") {
                    Text("\(state.webViewCount)")
                        .foregroundStyle(state.webViewCount > 1 ? .orange : .secondary)
                        .monospacedDigit()
                }
                LabeledContent("Live news player") {
                    Text(state.newsLivePlayerVisible ? "Active" : "Hidden")
                        .foregroundStyle(state.newsLivePlayerVisible ? .orange : .secondary)
                }
            }

            Section {
                Toggle("Enable web overlays", isOn: Binding(
                    get: { controller.prefs.current.webOverlaysEnabled },
                    set: { v in controller.prefs.update { $0.webOverlaysEnabled = v } }))
                Toggle("Allow remote URLs", isOn: Binding(
                    get: { controller.prefs.current.webOverlayAllowRemoteURLs },
                    set: { v in controller.prefs.update { $0.webOverlayAllowRemoteURLs = v } }))
                Toggle("Web debug tools", isOn: Binding(
                    get: { controller.prefs.current.webOverlayDebugEnabled },
                    set: { v in controller.prefs.update { $0.webOverlayDebugEnabled = v } }))
                if let err = state.webOverlayLastError {
                    LabeledContent("Last web error") {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Label("Web Overlays (experimental)", systemImage: "globe")
            } footer: {
                Text("Enables HTML/JS overlays powered by WKWebView. Keep disabled unless needed — each active web view uses GPU resources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 2: Voice

    private var voiceTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $voiceSubTab) {
                Text("Speech").tag(0)
                Text("Wake Word").tag(1)
                Text("Commands").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if voiceSubTab == 0 {
                VoiceSettingsView(state: state, controller: controller)
            } else if voiceSubTab == 1 {
                wakeWordContent
            } else {
                commandsContent
            }
        }
    }

    private var wakeWordContent: some View {
        Form {
            Section("Detector") {
                Toggle("Always-on wake word", isOn: wakeEnabledBinding)
                LabeledContent("Status") {
                    Text(state.wakeWordStatus.label).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Threshold")
                    Slider(value: thresholdBinding, in: 0.05...0.95)
                    Text(String(format: "%.2f", controller.prefs.current.wakeWord.threshold))
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }
            }
            Section("Model") {
                TextField("Sherpa-onnx model directory",
                          text: sherpaModelDirectoryBinding)
                TextField("Keywords file (keywords.txt)",
                          text: stringBinding(\.sherpaKeywordsFilePath, default: ""))
                Text("Drop `sherpa-onnx.xcframework` into `Vendor/`, then point these at the extracted KWS model + keywords file. See README §Phase 2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var commandsContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $commandsSubTab) {
                Text("Phrase Library").tag(0)
                Text("Unmatched Commands").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if commandsSubTab == 0 {
                CommandPhrasesView(store: controller.phraseStore)
            } else {
                UnmatchedCommandsView(controller: controller)
            }
        }
    }

    // MARK: - Tab 3: Conversation

    private var conversationTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $convSubTab) {
                Text("Mode & Memory").tag(0)
                Text("Personality").tag(1)
                Text("Responses").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if convSubTab == 0 {
                conversationModeContent
            } else if convSubTab == 1 {
                PersonalitySettingsView(controller: controller)
            } else {
                ResponsePlaybookView(controller: controller)
            }
        }
    }

    private var conversationModeContent: some View {
        Form {
            Section {
                Toggle("Enable conversational mode", isOn: Binding(
                    get: { controller.prefs.current.conversationalModeEnabled },
                    set: { v in controller.prefs.update { $0.conversationalModeEnabled = v } }))
                Toggle("Persistent conversation session", isOn: Binding(
                    get: { controller.prefs.current.persistentConversationEnabled },
                    set: { v in controller.prefs.update { $0.persistentConversationEnabled = v } }))
                Text("Jarvis listens continuously after the wake word — up to 10 minutes of inactivity — without requiring the wake phrase again.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Follow-up resolver", isOn: Binding(
                    get: { controller.prefs.current.conversationalFollowUpEnabled },
                    set: { v in controller.prefs.update { $0.conversationalFollowUpEnabled = v } }))
                LabeledContent("Session flush delay") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { controller.prefs.current.conversationalSessionFlushDelay },
                            set: { v in controller.prefs.update { $0.conversationalSessionFlushDelay = v } }
                        ), in: 1...30, step: 1)
                        .frame(width: 140)
                        Text("\(Int(controller.prefs.current.conversationalSessionFlushDelay))s")
                            .monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
            } header: {
                Label("Mode", systemImage: "bubble.left.and.bubble.right")
            }

            Section {
                LabeledContent("Auto-save memory") {
                    Picker("", selection: Binding(
                        get: { controller.prefs.current.conversationalMemoryAutoSave },
                        set: { v in controller.prefs.update { $0.conversationalMemoryAutoSave = v } }
                    )) {
                        Text("Off").tag("off")
                        Text("Ask me").tag("ask")
                        Text("Project items only").tag("auto_project")
                        Text("Everything").tag("auto_all")
                    }
                    .pickerStyle(.menu).frame(width: 180)
                }
                Text("\"Project items only\" auto-saves code decisions, bugs, milestones. \"Everything\" also saves preferences and facts.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Save raw transcripts", isOn: Binding(
                    get: { controller.prefs.current.conversationalSaveRawTranscripts },
                    set: { v in controller.prefs.update { $0.conversationalSaveRawTranscripts = v } }))
                Text("Stores every full transcript in conversation_log.json (200-turn rolling window). Useful for debugging. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Write Obsidian daily notes", isOn: Binding(
                    get: { controller.prefs.current.conversationalDailyNotesEnabled },
                    set: { v in controller.prefs.update { $0.conversationalDailyNotesEnabled = v } }))
                Text("Appends conversation highlights to {vaultPath}/Jarvis/YYYY-MM-DD.md after each session flush.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Memory & Logging", systemImage: "memorychip")
            }

            Section {
                Toggle("Enable project knowledge retrieval", isOn: Binding(
                    get: { controller.prefs.current.projectKnowledgeEnabled },
                    set: { v in controller.prefs.update { $0.projectKnowledgeEnabled = v } }))
                LabeledContent("Project docs folder") {
                    HStack(spacing: 8) {
                        Text(controller.prefs.current.projectDocsPath ?? "Not set")
                            .font(.caption)
                            .foregroundStyle(controller.prefs.current.projectDocsPath == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Select folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                controller.prefs.update { $0.projectDocsPath = url.path }
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        if controller.prefs.current.projectDocsPath != nil {
                            Button("Clear") {
                                controller.prefs.update { $0.projectDocsPath = nil }
                            }
                            .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
                        }
                    }
                }
                Text("Jarvis scans FEATURES.md, TODO.md, and CLAUDE.md in this folder for project-reflection answers.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Project Knowledge", systemImage: "folder.badge.questionmark")
            }

            Section {
                Toggle("Enable proactivity", isOn: Binding(
                    get: { controller.proactivity.settings.enabled },
                    set: { controller.proactivity.settings.enabled = $0 }))
                Toggle("Calendar meetings", isOn: Binding(
                    get: { controller.proactivity.settings.calendarEnabled },
                    set: { controller.proactivity.settings.calendarEnabled = $0 }))
                Toggle("Todoist tasks", isOn: Binding(
                    get: { controller.proactivity.settings.todoistEnabled },
                    set: { controller.proactivity.settings.todoistEnabled = $0 }))
                Toggle("GitHub notifications", isOn: Binding(
                    get: { controller.proactivity.settings.githubEnabled },
                    set: { controller.proactivity.settings.githubEnabled = $0 }))
                Toggle("Shopify alerts", isOn: Binding(
                    get: { controller.proactivity.settings.shopifyEnabled },
                    set: { controller.proactivity.settings.shopifyEnabled = $0 }))
                Toggle("News", isOn: Binding(
                    get: { controller.proactivity.settings.newsEnabled },
                    set: { controller.proactivity.settings.newsEnabled = $0 }))
                Toggle("Obsidian vault", isOn: Binding(
                    get: { controller.proactivity.settings.obsidianEnabled },
                    set: { controller.proactivity.settings.obsidianEnabled = $0 }))
            } header: {
                Label("Proactivity Sources", systemImage: "bell.badge")
            } footer: {
                Text("Proactive alerts surface relevant information before you ask for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 4: Models

    private var modelsTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $modelsSubTab) {
                Text("Providers").tag(0)
                Text("Vision").tag(1)
                Text("Intelligence").tag(2)
                Text("GitHub Intel").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if modelsSubTab == 0 {
                llmProvidersContent
            } else if modelsSubTab == 1 {
                visionContent
            } else if modelsSubTab == 2 {
                IntelligenceSettingsView(controller: controller)
            } else {
                GitHubIntelligenceSettingsView(controller: controller)
            }
        }
    }

    private var llmProvidersContent: some View {
        Form {
            Section("Provider Mode") {
                Picker("Mode", selection: llmModeBinding) {
                    ForEach(LLMProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Auto tries xAI → MiniMax → Gemini → llama.cpp, skipping unavailable providers. Local-only keeps everything offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MiniMax") {
                Toggle("Enabled", isOn: boolBinding(\.miniMaxEnabled))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Base URL  (e.g. https://api.minimax.io/v1)",
                              text: nonOptStringBinding(\.miniMaxBaseURL))
                    HStack(spacing: 6) {
                        Text("Quick fill:").font(.caption2).foregroundStyle(.secondary)
                        Button("International") {
                            controller.prefs.update { $0.miniMaxBaseURL = "https://api.minimax.io/v1" }
                        }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                        Button("China") {
                            controller.prefs.update { $0.miniMaxBaseURL = "https://api.minimaxi.com/v1" }
                        }.font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                TextField("Model  (e.g. MiniMax-M2.7)", text: nonOptStringBinding(\.miniMaxModel))
                LabeledContent("Final endpoint") {
                    Text(controller.llmRouter.miniMax.previewEndpointURL)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        miniMaxTestResult = nil; miniMaxTestIsError = false; isTesting = true
                        Task {
                            let (r, e) = await testMiniMaxDetailed()
                            miniMaxTestResult = r; miniMaxTestIsError = e; isTesting = false
                        }
                    }.disabled(isTesting)
                    Button(miniMaxCurlCopied ? "Copied!" : "Copy curl") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(miniMaxCurlCommand(), forType: .string)
                        miniMaxCurlCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { miniMaxCurlCopied = false }
                    }.font(.caption).buttonStyle(.bordered).controlSize(.small)
                }
                if let r = miniMaxTestResult {
                    Text(r)
                        .foregroundStyle(miniMaxTestIsError ? Color.red : Color.green)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("API key → Connections tab. streaming=off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("xAI (Grok)") {
                Toggle("Enabled", isOn: boolBinding(\.xaiEnabled))
                TextField("Base URL  (e.g. https://api.x.ai/v1)",
                          text: nonOptStringBinding(\.xaiBaseURL))
                TextField("Model  (e.g. grok-3-mini, grok-3, grok-beta)",
                          text: nonOptStringBinding(\.xaiModel))
                LabeledContent("Final endpoint") {
                    Text(controller.llmRouter.xai.previewEndpointURL)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        xaiTestResult = nil; xaiTestIsError = false; isTesting = true
                        Task {
                            let (r, e) = await controller.llmRouter.xai.testConnection()
                            xaiTestResult = r; xaiTestIsError = e; isTesting = false
                        }
                    }.disabled(isTesting)
                }
                if let r = xaiTestResult {
                    Text(r)
                        .foregroundStyle(xaiTestIsError ? Color.red : Color.green)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("API key → Connections tab. Models: grok-3-mini (fast/cheap), grok-3 (full).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Gemini") {
                Toggle("Enabled", isOn: boolBinding(\.geminiEnabled))
                TextField("Base URL (e.g. https://generativelanguage.googleapis.com/v1beta)",
                          text: nonOptStringBinding(\.geminiBaseURL))
                TextField("Model (e.g. gemini-1.5-flash, gemini-2.5-pro)",
                          text: nonOptStringBinding(\.geminiModel))
                TextField("Vision model (often same as text model)",
                          text: nonOptStringBinding(\.geminiVisionModel))
                HStack(spacing: 8) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        geminiTestResult = nil; geminiTestIsError = false; isTesting = true
                        Task {
                            let (r, e) = await controller.llmRouter.gemini.testConnection()
                            geminiTestResult = r; geminiTestIsError = e; isTesting = false
                        }
                    }.disabled(isTesting)
                }
                if let r = geminiTestResult {
                    Text(r)
                        .foregroundStyle(geminiTestIsError ? Color.red : Color.green)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("API key → Connections tab. Model names are free-form (1.5-flash, 2.5-pro, …).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Local LLM Provider (llama.cpp)") {
                Toggle("Enabled", isOn: boolBinding(\.llamaCppEnabled))
                TextField("Base URL  (e.g. http://localhost:8080/v1)",
                          text: nonOptStringBinding(\.llamaCppBaseURL))
                TextField("Model name (must match the loaded model identifier)",
                          text: nonOptStringBinding(\.llamaCppModel))
                HStack {
                    Button("Test connection") {
                        localLLMTestResult = nil; isTesting = true
                        Task { localLLMTestResult = await testLocalLLM(); isTesting = false }
                    }.disabled(isTesting)
                    if let r = localLLMTestResult {
                        Text(r).foregroundStyle(r.hasPrefix("Connected") ? Color.green : Color.red)
                            .font(.caption)
                    }
                }
                LabeledContent("Expected endpoint") {
                    Text(controller.prefs.current.llamaCppBaseURL
                         .trimmingCharacters(in: .init(charactersIn: "/")) + "/chat/completions")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("Start llama.cpp server (port 8080 by default): llama-server -m model.gguf --port 8080")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Last provider") {
                    Text(state.llmProviderUsed.isEmpty ? "None" : state.llmProviderUsed)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last model") {
                    Text(state.llmModelUsed.isEmpty ? "—" : state.llmModelUsed)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last latency") {
                    Text(state.llmLatencyMs == 0 ? "—" : "\(state.llmLatencyMs) ms")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("LLM fallback used") {
                    Text(state.llmFallbackUsed ? "Yes" : "No").foregroundStyle(.secondary)
                }
                if let err = state.llmLastError {
                    LabeledContent("Last error") {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var visionContent: some View {
        Form {
            Section {
                Toggle("Allow camera frames to leave the machine (cloud vision)",
                       isOn: Binding(
                           get: { controller.prefs.current.cloudVisionConsent },
                           set: { v in controller.prefs.update { $0.cloudVisionConsent = v } }))
                Text("When off, vision uses on-device Apple Vision only. No camera frame is ever sent to MiniMax or Gemini until you turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.prefs.current.cloudVisionConsent {
                    Picker("Preferred provider", selection: Binding(
                        get: { controller.prefs.current.preferredVisionProviderRaw },
                        set: { v in controller.prefs.update { $0.preferredVisionProviderRaw = v } }
                    )) {
                        Text("MiniMax Vision").tag("minimax")
                        Text("Gemini Vision").tag("gemini")
                        Text("Apple Vision only (on-device)").tag("apple")
                    }.pickerStyle(.menu)
                }
                if !state.lastVisionSelectorChoice.isEmpty {
                    LabeledContent("Last call routed to") {
                        Text(state.lastVisionSelectorChoice).foregroundStyle(.secondary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if let r = state.lastVisionFallbackReason {
                    Label("Last fallback: \(r)", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Label("Vision Routing", systemImage: "point.3.connected.trianglepath.dotted")
            }

            Section {
                Toggle("Enable AI Vision", isOn: Binding(
                    get: { controller.prefs.current.useLLMForVision },
                    set: { v in controller.prefs.update { $0.useLLMForVision = v } }))
                if controller.prefs.current.useLLMForVision {
                    let visionModel = controller.prefs.current.miniMaxVisionModel
                        .trimmingCharacters(in: .whitespaces)
                    let textModel = controller.prefs.current.miniMaxModel
                        .trimmingCharacters(in: .whitespaces)
                    LabeledContent("Status") {
                        if !controller.prefs.current.miniMaxEnabled {
                            Label("MiniMax disabled — enable in Providers",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                        } else if textModel.isEmpty && visionModel.isEmpty {
                            Label("No model configured — set in Providers",
                                  systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).font(.caption)
                        } else {
                            let m = visionModel.isEmpty ? textModel : visionModel
                            Label(m, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                        }
                    }
                    TextField("Vision model override (optional)", text: Binding(
                        get: { controller.prefs.current.miniMaxVisionModel },
                        set: { v in controller.prefs.update { $0.miniMaxVisionModel = v } }))
                    Text("Leave blank to use the text model from Providers — MiniMax M2+ supports images on the same endpoint.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    LabeledContent("Image Max Width") {
                        Stepper(value: Binding(
                            get: { controller.prefs.current.visionImageMaxWidth },
                            set: { v in controller.prefs.update { $0.visionImageMaxWidth = v } }
                        ), in: 256...2048, step: 128) {
                            Text("\(controller.prefs.current.visionImageMaxWidth) px")
                                .foregroundStyle(.secondary).frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Label("AI Vision (MiniMax)", systemImage: "eye.fill")
            } footer: {
                Text("When enabled, \"what can you see\" and similar commands send a camera frame to MiniMax.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vision Behaviour") {
                Toggle("Auto-open camera overlay", isOn: Binding(
                    get: { controller.prefs.current.visionAutoOpenOverlay },
                    set: { v in controller.prefs.update { $0.visionAutoOpenOverlay = v } }))
                Toggle("Save descriptions to memory", isOn: Binding(
                    get: { controller.prefs.current.visionSaveToMemory },
                    set: { v in controller.prefs.update { $0.visionSaveToMemory = v } }))
                Toggle("Verbose descriptions", isOn: Binding(
                    get: { controller.prefs.current.visionVerboseDescriptions },
                    set: { v in controller.prefs.update { $0.visionVerboseDescriptions = v } }))
            }

            if !state.lastVisionSummary.isEmpty || state.lastVisionTotalMs > 0 {
                Section("Last Vision Result") {
                    if !state.lastVisionProvider.isEmpty {
                        LabeledContent("Provider") {
                            Text(state.lastVisionProvider).foregroundStyle(.secondary)
                        }
                    }
                    if !state.lastVisionModelUsed.isEmpty {
                        LabeledContent("Model") {
                            Text(state.lastVisionModelUsed)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    if state.lastVisionTotalMs > 0 {
                        LabeledContent("Latency") {
                            Text("\(state.lastVisionTotalMs) ms total").foregroundStyle(.secondary)
                        }
                    }
                    if state.lastVisionImageSizeKB > 0 {
                        LabeledContent("Image size") {
                            Text("\(state.lastVisionImageSizeKB) KB").foregroundStyle(.secondary)
                        }
                    }
                    if !state.lastVisionSummary.isEmpty {
                        LabeledContent("Last description") {
                            Text(state.lastVisionSummary)
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).lineLimit(4)
                        }
                    }
                    if let err = state.lastVisionError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 5: Connections

    private var connectionsTab: some View {
        Form {
            Section("Home Assistant") {
                SecureField("Long-lived access token",
                            text: keychainTokenBinding(account: KeychainAccount.homeAssistantToken))
                if controller.prefs.hasSecureToken(account: KeychainAccount.homeAssistantToken) {
                    Label("Token stored securely in Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                }
                Text("Base URL and entity aliases are configured in Integrations.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Todoist") {
                SecureField("API token",
                            text: keychainTokenBinding(account: KeychainAccount.todoistAPIToken))
                    .help("Get your token at todoist.com → Settings → Integrations → API token")
                    .onSubmit { controller.rebuildTodoist() }
                if controller.prefs.hasSecureToken(account: KeychainAccount.todoistAPIToken) {
                    Label("Connected (Keychain)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                }
            }

            Section("GitHub") {
                SecureField("Personal access token",
                            text: keychainTokenBinding(account: KeychainAccount.githubPersonalAccessToken))
                    .help("Create at github.com → Settings → Developer Settings → Personal access tokens. Needs 'notifications' scope.")
                if controller.prefs.hasSecureToken(account: KeychainAccount.githubPersonalAccessToken) {
                    Label("Connected (Keychain)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                }
            }

            Section("Shopify") {
                SecureField("Admin access token",
                            text: keychainTokenBinding(account: KeychainAccount.shopifyAccessToken))
                    .help("Create a private app in your Shopify admin and copy the Admin API access token.")
                if controller.prefs.hasSecureToken(account: KeychainAccount.shopifyAccessToken) {
                    Label("Connected (Keychain)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                }
                Text("Shop domain and stock threshold are configured in Integrations.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spotify") {
                SecureField("Personal API Token",
                            text: keychainTokenBinding(account: KeychainAccount.spotifyPersonalToken))
                    .help("Get from developer.spotify.com → OAuth Playground. Needs user-read-playback-state and user-modify-playback-state.")
                if controller.prefs.hasSecureToken(account: KeychainAccount.spotifyPersonalToken) {
                    Label("Connected (Keychain)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                }
                Text("developer.spotify.com → your app → OAuth Playground → scopes: user-read-playback-state, user-modify-playback-state")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MiniMax") {
                SecureField("API key", text: $miniMaxKeyDraft)
                    .onAppear { miniMaxKeyDraft = Keychain.get(KeychainAccount.miniMaxAPIKey) ?? "" }
                    .onChange(of: miniMaxKeyDraft) { _, v in
                        Keychain.set(v, for: KeychainAccount.miniMaxAPIKey)
                    }
                Text("Provider settings (base URL, model, test) are in Models → Providers.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("xAI / Grok") {
                SecureField("API key", text: $xaiKeyDraft)
                    .onAppear { xaiKeyDraft = Keychain.get(KeychainAccount.xaiAPIKey) ?? "" }
                    .onChange(of: xaiKeyDraft) { _, v in
                        Keychain.set(v, for: KeychainAccount.xaiAPIKey)
                    }
                Text("Get a key at console.x.ai — models: grok-3-mini (fast/cheap), grok-3 (full).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Gemini") {
                SecureField("API key", text: $geminiKeyDraft)
                    .onAppear { geminiKeyDraft = Keychain.get(KeychainAccount.geminiAPIKey) ?? "" }
                    .onChange(of: geminiKeyDraft) { _, v in
                        Keychain.set(v, for: KeychainAccount.geminiAPIKey)
                    }
                Text("Get a key at aistudio.google.com. Provider settings are in Models → Providers.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Gateway URL") {
                    Text(":\(controller.prefs.current.brainServerPort)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(controller.gatewayDiagnostics.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(controller.gatewayDiagnostics.statusLine)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Gateway token") {
                    Button("Manage in Developer > Brain API") { tab = .developer }
                        .buttonStyle(.borderless)
                }
                LabeledContent("Android WebSocket") {
                    Text("wss://…:\(controller.prefs.current.brainServerPort)/v1/android/ws")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Paired devices") {
                    Text("\(GatewayAuthStore.shared.pairedDevices.filter { !$0.isRevoked }.count)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Mac Brain Gateway", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 6: Integrations

    private var integrationsTab: some View {
        Form {
            // ── Home Assistant ──────────────────────────────────────────
            Group {
                Section {
                    TextField("Base URL (e.g. http://192.168.1.20:8123)",
                              text: stringBinding(\.smartHomeBaseURL, default: ""))
                    Button("Test connection") {
                        Task { await controller.refreshSmartHomeFromPrefs() }
                    }
                    if controller.prefs.hasSecureToken(account: KeychainAccount.homeAssistantToken) {
                        Label("Token configured (Keychain) — set in Connections tab",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    } else {
                        Label("No token — set in Connections tab", systemImage: "key.slash")
                            .foregroundStyle(.orange).font(.caption)
                    }
                } header: {
                    Label("Home Assistant", systemImage: "house")
                }

                Section {
                    Text("Map spoken names to Home Assistant entity IDs. Aliases take priority over fuzzy matching.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(controller.homeAliases.aliases) { alias in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alias.friendlyName).font(.subheadline)
                                Text(alias.entityID).font(.caption).foregroundStyle(.secondary).monospaced()
                            }
                            Spacer()
                        }
                    }
                    .onDelete { indices in
                        for idx in indices {
                            controller.homeAliases.remove(id: controller.homeAliases.aliases[idx].id)
                        }
                    }
                    Button("Add alias") { showingAddAlias = true }
                } header: {
                    Label("HA Entity Aliases", systemImage: "tag")
                }
            }

            // ── Services ────────────────────────────────────────────────
            Group {
                Section("Calendar") {
                    Toggle("Google Calendar", isOn: boolBinding(\.googleCalendarEnabled))
                }

                Section {
                    TextField("Shop domain (e.g. mystore.myshopify.com)",
                              text: stringBinding(\.shopifyShopDomain, default: ""))
                    if controller.prefs.hasSecureToken(account: KeychainAccount.shopifyAccessToken) {
                        Label("Token configured (Keychain) — set in Connections tab",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                    Stepper(
                        "Low stock alert threshold: \(controller.prefs.current.shopifyLowStockThreshold)",
                        value: Binding(
                            get: { controller.prefs.current.shopifyLowStockThreshold },
                            set: { v in controller.prefs.update { $0.shopifyLowStockThreshold = v } }
                        ),
                        in: 1...50
                    )
                } header: {
                    Label("Shopify", systemImage: "cart")
                }

                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.prefs.current.obsidianVaultPath ?? "No vault selected")
                                .foregroundStyle(controller.prefs.current.obsidianVaultPath == nil ? .secondary : .primary)
                                .lineLimit(2).truncationMode(.middle)
                            if let path = controller.prefs.current.obsidianVaultPath, !path.isEmpty {
                                let count = controller.obsidianVault.noteCount
                                Label(count > 0 ? "\(count) notes indexed" : "Indexing…",
                                      systemImage: count > 0 ? "checkmark.circle.fill" : "clock")
                                    .font(.caption).foregroundStyle(count > 0 ? .green : .secondary)
                            }
                        }
                        Spacer()
                        Button("Choose Vault…") { pickVaultFolder() }.buttonStyle(.bordered)
                        if controller.prefs.current.obsidianVaultPath != nil {
                            Button("Clear") {
                                controller.prefs.update { $0.obsidianVaultPath = nil }
                            }
                            .buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                    Toggle("Inject vault notes into every AI query",
                           isOn: Binding(
                               get: { controller.prefs.current.obsidianLLMContextEnabled },
                               set: { v in controller.prefs.update { $0.obsidianLLMContextEnabled = v } }))
                    Stepper(
                        "Max notes per query: \(controller.prefs.current.obsidianMaxContextNotes)",
                        value: Binding(
                            get: { controller.prefs.current.obsidianMaxContextNotes },
                            set: { v in controller.prefs.update { $0.obsidianMaxContextNotes = v } }
                        ), in: 1...8
                    )
                    Toggle("Surface vault changes (proactivity)",
                           isOn: Binding(
                               get: { controller.prefs.current.obsidianProactivityEnabled },
                               set: { v in controller.prefs.update { $0.obsidianProactivityEnabled = v } }))
                    TextField("#jarvis, #review, #urgent", text: Binding(
                        get: { controller.prefs.current.obsidianWatchTags.joined(separator: ", ") },
                        set: { raw in
                            let tags = raw.components(separatedBy: ",")
                                .map {
                                    $0.trimmingCharacters(in: .whitespaces)
                                      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                                }
                                .filter { !$0.isEmpty }
                            controller.prefs.update { $0.obsidianWatchTags = tags }
                        }))
                    Text("Watch tags (comma-separated): notes tagged with these trigger an alert.")
                        .font(.caption).foregroundStyle(.secondary)
                    if controller.prefs.current.obsidianVaultPath != nil {
                        Button("Re-index vault now") {
                            Task { await controller.obsidianVault.reindex() }
                        }
                    }
                } header: {
                    Label("Obsidian Vault", systemImage: "book.closed")
                } footer: {
                    Text("Point Jarvis at your Obsidian vault folder. Notes are read from disk for AI context injection and watch-tag alerts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // ── Android & Network ───────────────────────────────────────
            Group {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: controller.state.tailscaleConnected
                              ? "network" : "network.slash")
                            .foregroundColor(controller.state.tailscaleConnected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.state.tailscaleConnected
                                 ? "Tailscale connected" : "Tailscale not detected")
                                .fontWeight(.medium)
                            if let ip = controller.state.tailscaleIP {
                                Text(controller.state.tailscaleHostname ?? ip)
                                    .font(.caption).foregroundStyle(.secondary).monospaced()
                            } else {
                                Text("Install Tailscale on both Mac and phone")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Refresh") { controller.updateTailscaleState() }
                            .buttonStyle(.borderless).font(.caption)
                    }

                    LabeledContent("Android WebSocket URL") {
                        let port = controller.prefs.current.brainServerPort
                        let ip = controller.state.tailscaleIP ?? TailscaleService.findLocalIP() ?? "<your-ip>"
                        Text("wss://\(ip):\(port)/v1/android/ws")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Gateway token and pairing are managed in Developer > Brain API.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Label("Android Bridge", systemImage: "iphone")
                } footer: {
                    if controller.state.tailscaleConnected {
                        let port = controller.prefs.current.brainServerPort
                        Text("Android connects to: \(controller.state.tailscaleIP.map { "wss://\($0):\(port)/v1/android/ws" } ?? "—")")
                            .font(.caption).monospaced()
                    }
                }

                Section {
                    Toggle("Announce caller names", isOn: Binding(
                        get: { controller.prefs.current.androidSpeakCallerNames },
                        set: { v in controller.prefs.update { $0.androidSpeakCallerNames = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Announce message senders", isOn: Binding(
                        get: { controller.prefs.current.androidSpeakMessageSenders },
                        set: { v in controller.prefs.update { $0.androidSpeakMessageSenders = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Include message preview in speech", isOn: Binding(
                        get: { controller.prefs.current.androidShowMessagePreviews },
                        set: { v in controller.prefs.update { $0.androidShowMessagePreviews = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Mute WhatsApp announcements", isOn: Binding(
                        get: { controller.prefs.current.androidMuteWhatsApp },
                        set: { v in controller.prefs.update { $0.androidMuteWhatsApp = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Mute SMS announcements", isOn: Binding(
                        get: { controller.prefs.current.androidMuteSMS },
                        set: { v in controller.prefs.update { $0.androidMuteSMS = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Announce app notifications", isOn: Binding(
                        get: { controller.prefs.current.androidSpeakNotifications },
                        set: { v in controller.prefs.update { $0.androidSpeakNotifications = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                    Toggle("Auto-open overlay on call/message", isOn: Binding(
                        get: { controller.prefs.current.androidAutoOpenOverlay },
                        set: { v in controller.prefs.update { $0.androidAutoOpenOverlay = v }
                               controller.syncAndroidEventReceiverPrefs() }))
                } header: {
                    Label("Android Announcements", systemImage: "speaker.wave.2")
                } footer: {
                    Text("Incoming calls always speak immediately regardless of quiet hours.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Bridge Diagnostics") {
                    let diag = controller.androidBridge?.diagnostics ?? AndroidBridgeDiagnostics()
                    HStack {
                        Label(diag.isConnected ? "Phone connected" : "Phone offline",
                              systemImage: diag.isConnected
                              ? "antenna.radiowaves.left.and.right"
                              : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(diag.isConnected ? .green : .secondary)
                        Spacer()
                        if diag.isConnected && !diag.deviceName.isEmpty {
                            Text(diag.deviceName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if diag.isConnected {
                        if diag.batteryLevel >= 0 {
                            LabeledContent("Battery", value: "\(diag.batteryLevel)%")
                        }
                        if diag.roundtripLatencyMs >= 0 {
                            LabeledContent("Latency", value: "\(diag.roundtripLatencyMs) ms")
                        }
                        if let hb = diag.lastHeartbeat {
                            let secs = Int(-hb.timeIntervalSinceNow)
                            LabeledContent("Last heartbeat",
                                           value: secs < 10 ? "Just now" : "\(secs)s ago")
                        }
                    }
                    if diag.authFailures > 0 {
                        LabeledContent("Auth failures", value: "\(diag.authFailures)")
                            .foregroundColor(.red)
                    }
                    if diag.timeouts > 0 {
                        LabeledContent("Timeouts", value: "\(diag.timeouts)").foregroundColor(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddAlias) { addAliasSheet }
    }

    // MARK: - Tab 8: News & Feeds

    private var newsFeedsTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $newsFeedsSubTab) {
                Text("News").tag(0)
                Text("Reddit").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if newsFeedsSubTab == 0 {
                NewsSettingsContainer(
                    channelStore: controller.newsChannelStore,
                    feedStore: controller.newsStore,
                    scheduler: controller.newsScheduler
                )
            } else {
                RedditSettingsView(store: controller.redditStore)
            }
        }
    }

    // MARK: - Tab 9: Devices

    private var devicesTab: some View {
        Form {
            Section("Daemon") {
                LabeledContent("Status") {
                    Text(DaemonManager.shared.status == .running ? "Connected" : "Disconnected")
                        .foregroundStyle(DaemonManager.shared.status == .running ? .green : .secondary)
                }
                LabeledContent("Port") { Text("8765") }
            }
            Section("Connected Devices") {
                let deviceCount = DaemonManager.shared.connectedDevices
                if deviceCount == 0 {
                    Text("No devices connected").foregroundStyle(.secondary)
                } else {
                    Text("\(deviceCount) device(s) connected")
                        .foregroundStyle(.secondary)
                    Text("See Developer → Brain API for detailed device info.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Recent Handoffs") {
                Text("Last 5 handoffs appear here when cross-device continuity is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 10: Developer

    private var developerTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $devSubTab) {
                Text("Subsystems").tag(0)
                Text("Logging").tag(1)
                Text("Brain API").tag(2)
                Text("Training").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if devSubTab == 0 {
                devSubsystemsContent
            } else if devSubTab == 1 {
                devLoggingContent
            } else if devSubTab == 2 {
                MacBrainGatewaySettingsView(controller: controller)
            } else {
                TrainingDataView(engine: controller.learningEngine)
            }
        }
    }

    private var devSubsystemsContent: some View {
        Form {
            Section {
                Text("Advanced settings — use with care.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Emergency Safe Mode", isOn: emergencySafeModeBinding)
                if controller.prefs.current.emergencySafeMode {
                    Label("ACTIVE — most subsystems disabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                Text(controller.prefs.current.emergencySafeMode
                     ? "ON — only UI and health monitor are active."
                     : "OFF — all subsystems start normally.")
                    .font(.caption)
                    .foregroundStyle(controller.prefs.current.emergencySafeMode ? .orange : .secondary)
            } header: {
                Label("Emergency Mode", systemImage: "exclamationmark.triangle")
            }

            Section {
                Toggle("Camera (AVCaptureSession)",
                       isOn: subsystemBinding(\.subsystemCameraEnabled))
                Toggle("Wake Word + STT pipeline",
                       isOn: subsystemBinding(\.subsystemWakeWordEnabled))
                Toggle("WebSocket server (Android bridge)",
                       isOn: subsystemBinding(\.subsystemWebSocketEnabled))
                Toggle("Tailscale polling",
                       isOn: subsystemBinding(\.subsystemTailscaleEnabled))
                Toggle("News scheduler (WKWebView)",
                       isOn: subsystemBinding(\.subsystemNewsEnabled))
                Toggle("Weather proactivity",
                       isOn: subsystemBinding(\.subsystemWeatherProviderEnabled))
                Toggle("Calendar proactivity",
                       isOn: subsystemBinding(\.subsystemCalendarProviderEnabled))
                Toggle("Todoist proactivity",
                       isOn: subsystemBinding(\.subsystemTodoistProviderEnabled))
                Toggle("GitHub proactivity",
                       isOn: subsystemBinding(\.subsystemGitHubProviderEnabled))
                Toggle("Home Assistant proactivity",
                       isOn: subsystemBinding(\.subsystemHAProviderEnabled))
            } header: {
                Label("Subsystem Isolation", systemImage: "square.stack.3d.up")
            } footer: {
                Text("Subsystem isolation only applies when Emergency Safe Mode is ON.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Shopify proactivity",
                       isOn: subsystemBinding(\.subsystemShopifyProviderEnabled))
                Toggle("Obsidian proactivity",
                       isOn: subsystemBinding(\.subsystemObsidianEnabled))
                Toggle("Semantic memory index",
                       isOn: subsystemBinding(\.subsystemSemanticMemoryEnabled))
                Toggle("Conversation summariser",
                       isOn: subsystemBinding(\.subsystemConversationSummariserEnabled))
            } header: {
                Label("More Subsystems", systemImage: "square.stack.3d.up.slash")
            }

            if let hm = controller.healthMonitor {
                Section("Health Monitor") {
                    LabeledContent("Memory (resident)") {
                        Text("\(hm.lastResidentMB) MB")
                            .foregroundStyle(hm.lastResidentMB > 600 ? .orange : .secondary)
                            .monospacedDigit()
                    }
                    if hm.emergencyStopFired {
                        Label("Emergency stop fired this session",
                              systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }

            Section {
                LabeledContent("Raw WS messages") {
                    Text("\(state.androidBridgeRawMessagesReceived)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Parse failures") {
                    Text("\(state.androidBridgeParseFailures)").monospacedDigit()
                        .foregroundStyle(state.androidBridgeParseFailures > 0 ? .orange : .secondary)
                }
                LabeledContent("Phone events routed") {
                    Text("\(state.androidBridgePhoneEventCount)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Pending requests") {
                    Text("\(state.androidBridgePendingRequestCount)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            } header: {
                Label("Bridge Counters", systemImage: "chart.bar")
            } footer: {
                Text("Restart Jarvis after any subsystem changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var devLoggingContent: some View {
        Form {
            Section {
                Toggle("Show routing diagnostics", isOn: Binding(
                    get: { controller.prefs.current.conversationalDiagnosticsEnabled },
                    set: { v in controller.prefs.update { $0.conversationalDiagnosticsEnabled = v } }))
                Text("Logs ConversationRouter classification results to the debug overlay after every transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Routing Diagnostics", systemImage: "chart.bar.doc.horizontal")
            }

            Section {
                Toggle("Enable unknown-command issue logging",
                       isOn: boolBinding(\.githubIssueLoggingEnabled))
                Text("When enabled, Jarvis files a GitHub issue for every command it doesn't yet understand.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.prefs.current.githubIssueLoggingEnabled {
                    Group {
                        Toggle("Auto-create issues on unknown commands",
                               isOn: boolBinding(\.githubIssueAutoCreate))
                        SecureField("GitHub token (repo scope)", text: $githubIssueTokenDraft)
                            .onAppear {
                                githubIssueTokenDraft =
                                    Keychain.get(KeychainAccount.githubIssuesToken) ?? ""
                            }
                            .onChange(of: githubIssueTokenDraft) { _, v in
                                Keychain.set(v, for: KeychainAccount.githubIssuesToken)
                            }
                        TextField("GitHub username (optional)",
                                  text: nonOptStringBinding(\.githubIssueUsername))
                        TextField("Repository owner (e.g. chrisgwynne)",
                                  text: nonOptStringBinding(\.githubIssueRepoOwner))
                        TextField("Repository name (e.g. jarvis)",
                                  text: nonOptStringBinding(\.githubIssueRepoName))
                        TextField("Labels (comma-separated)",
                                  text: nonOptStringBinding(\.githubIssueLabelsCSV))
                    }
                    Group {
                        LabeledContent("Cooldown") {
                            Stepper(value: Binding(
                                get: { controller.prefs.current.githubIssueCooldownSeconds },
                                set: { v in controller.prefs.update { $0.githubIssueCooldownSeconds = v } }
                            ), in: 5...600, step: 5) {
                                Text("\(controller.prefs.current.githubIssueCooldownSeconds) s")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 60, alignment: .trailing)
                            }
                        }
                        HStack(spacing: 8) {
                            Button(isTesting ? "Testing…" : "Test connection") {
                                githubIssueTestResult = nil
                                githubIssueTestIsError = false
                                isTesting = true
                                Task {
                                    let msg = await controller.githubIssueService.testConnection()
                                    githubIssueTestResult = msg
                                    githubIssueTestIsError = !msg.hasPrefix("✓")
                                    isTesting = false
                                }
                            }.disabled(isTesting)
                        }
                        if let r = githubIssueTestResult {
                            Text(r)
                                .foregroundStyle(githubIssueTestIsError ? Color.red : Color.green)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if let last = controller.prefs.current.githubIssueLastCreatedURL,
                           !last.isEmpty {
                            LabeledContent("Last issue") {
                                Text(last)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                                    .truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                        Text("Token stored in macOS Keychain — never written to preferences.json.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Label("GitHub Issue Logging", systemImage: "exclamationmark.bubble")
            }

            Section {
                Text("Android Test Event Injection").font(.subheadline).bold()
                HStack(spacing: 8) {
                    Button("Incoming Call") {
                        controller.androidBridge?.injectTestAndroidEvent(
                            type: .incomingCall, senderName: "Test Caller")
                    }.buttonStyle(.bordered)
                    Button("Missed Call") {
                        controller.androidBridge?.injectTestAndroidEvent(
                            type: .missedCall, senderName: "Test Caller")
                    }.buttonStyle(.bordered)
                    Button("SMS") {
                        controller.androidBridge?.injectTestAndroidEvent(
                            type: .smsReceived, senderName: "Test Sender")
                    }.buttonStyle(.bordered)
                    Button("Heartbeat") {
                        controller.androidBridge?.injectTestAndroidEvent(
                            type: .heartbeat, senderName: "")
                    }.buttonStyle(.bordered)
                }
                Text("Injects a fake Android event locally — no WebSocket needed.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Vision Diagnostics").font(.subheadline).bold().padding(.top, 4)
                HStack(spacing: 8) {
                    Button("Test Vision Action") {
                        Task { await controller.execute(.whatCanYouSee) }
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                }
                Text("Bypasses phrase routing and directly invokes the camera vision pipeline.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Test & Injection", systemImage: "hammer")
            } footer: {
                Text("Restart Jarvis after any subsystem changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - HA alias sheet

    private var addAliasSheet: some View {
        NavigationStack {
            Form {
                Section("Spoken name") {
                    TextField("e.g. desk lamp", text: $newAliasFriendlyName)
                }
                Section("Home Assistant entity ID") {
                    TextField("e.g. light.office_desk_lamp_main", text: $newAliasEntityID)
                        .monospaced()
                }
            }
            .navigationTitle("Add Entity Alias")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newAliasFriendlyName = ""; newAliasEntityID = ""
                        showingAddAlias = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        controller.homeAliases.add(
                            friendlyName: newAliasFriendlyName,
                            entityID: newAliasEntityID)
                        newAliasFriendlyName = ""; newAliasEntityID = ""
                        showingAddAlias = false
                    }
                    .disabled(
                        newAliasFriendlyName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newAliasEntityID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    // MARK: - Vault picker

    private func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        panel.message = "Choose your Obsidian vault folder"
        if panel.runModal() == .OK, let url = panel.url {
            controller.prefs.update { $0.obsidianVaultPath = url.path }
            Task { controller.obsidianVault.start() }
        }
    }

    // MARK: - AI connection tests

    private func testMiniMaxDetailed() async -> (String, Bool) {
        guard controller.prefs.current.miniMaxEnabled else {
            return ("⚠ MiniMax disabled in settings", true)
        }
        guard let key = Keychain.get(KeychainAccount.miniMaxAPIKey), !key.isEmpty else {
            return ("⚠ No API key entered (set in Connections tab)", true)
        }
        let finalURL = controller.llmRouter.miniMax.previewEndpointURL
        let model    = controller.prefs.current.miniMaxModel
        do {
            _ = try await controller.llmRouter.miniMax.complete(LLMRequest(
                systemPrompt: "Reply with the single word OK.",
                userPrompt:   "OK",
                temperature:  0.0,
                maxTokens:    20
            ))
            return ("✓ Connected\n\(finalURL)\nmodel: \(model)", false)
        } catch LLMError.http(let code, let body) {
            return ("HTTP \(code)\nURL: \(finalURL)\nmodel: \(model)\n\(body.prefix(400))", true)
        } catch {
            return ("Error: \(error.localizedDescription)\nURL: \(finalURL)", true)
        }
    }

    private func miniMaxCurlCommand() -> String {
        let url   = controller.llmRouter.miniMax.previewEndpointURL
        let model = controller.prefs.current.miniMaxModel
        return """
curl \(url) \\
  -H "Authorization: Bearer REDACTED" \\
  -H "Content-Type: application/json" \\
  -d '{"model":"\(model)","messages":[{"role":"user","content":"Say OK"}],"max_tokens":20,"stream":false}'
"""
    }

    private func testLocalLLM() async -> String {
        guard controller.prefs.current.llamaCppEnabled else { return "Disabled in Settings" }
        let ok = await controller.llmRouter.local.isAvailable()
        return ok ? "Connected ✓" : "Unavailable — is llama.cpp running? (llama-server --port 8080)"
    }

    // MARK: - Binding helpers

    private func nonOptStringBinding(_ key: WritableKeyPath<Preferences, String>) -> Binding<String> {
        Binding(
            get: { controller.prefs.current[keyPath: key] },
            set: { v in controller.prefs.update { $0[keyPath: key] = v } }
        )
    }

    private func identityStringBinding(_ key: WritableKeyPath<Preferences, String>) -> Binding<String> {
        Binding(
            get: { controller.prefs.current[keyPath: key] },
            set: { v in
                controller.prefs.update { $0[keyPath: key] = v }
                controller.syncIdentity()
            }
        )
    }

    private func identityOptStringBinding(_ key: WritableKeyPath<Preferences, String?>) -> Binding<String> {
        Binding(
            get: { controller.prefs.current[keyPath: key] ?? "" },
            set: { v in
                controller.prefs.update { $0[keyPath: key] = v.isEmpty ? nil : v }
                controller.syncIdentity()
            }
        )
    }

    private var llmModeBinding: Binding<LLMProviderMode> {
        Binding(
            get: { LLMProviderMode(rawValue: controller.prefs.current.llmProviderModeRaw) ?? .auto },
            set: { v in
                controller.prefs.update { $0.llmProviderModeRaw = v.rawValue }
                controller.syncLLMMode()
            }
        )
    }

    private func stringBinding(_ key: WritableKeyPath<Preferences, String?>,
                               default fallback: String) -> Binding<String> {
        Binding(
            get: { controller.prefs.current[keyPath: key] ?? fallback },
            set: { v in
                controller.prefs.update { $0[keyPath: key] = v.isEmpty ? nil : v }
            }
        )
    }

    private func keychainTokenBinding(account: String) -> Binding<String> {
        Binding(
            get: { Keychain.get(account) ?? "" },
            set: { v in controller.prefs.setSecureToken(v, account: account) }
        )
    }

    private func boolBinding(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.prefs.current[keyPath: key] },
            set: { v in controller.prefs.update { $0[keyPath: key] = v } }
        )
    }

    private func wakeBoolBinding(_ key: WritableKeyPath<WakeWordSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.prefs.current.wakeWord[keyPath: key] },
            set: { v in controller.prefs.update { $0.wakeWord[keyPath: key] = v } }
        )
    }

    private func subsystemBinding(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.prefs.current[keyPath: key] },
            set: { v in controller.prefs.update { $0[keyPath: key] = v } }
        )
    }

    private var emergencySafeModeBinding: Binding<Bool> {
        Binding(
            get: { controller.prefs.current.emergencySafeMode },
            set: { v in controller.prefs.update { $0.emergencySafeMode = v } }
        )
    }

    private var safeModeBinding: Binding<Bool> {
        Binding(
            get: { controller.prefs.current.safeMode },
            set: { newVal in
                controller.prefs.update { $0.safeMode = newVal }
                state.safeMode = newVal
                if newVal {
                    controller.ambientContext.samplingEnabled = false
                } else if controller.prefs.current.ambientModeEnabled {
                    controller.ambientContext.samplingEnabled = true
                }
            }
        )
    }

    private var wakeEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.prefs.current.wakeWord.enabled },
            set: { v in
                controller.prefs.update { $0.wakeWord.enabled = v }
                Task { await controller.rebuildWakeWord() }
            }
        )
    }

    private var sherpaModelDirectoryBinding: Binding<String> {
        Binding(
            get: { controller.prefs.current.sherpaModelDirectory ?? "" },
            set: { v in
                let cleaned: String? = v.isEmpty ? nil : v
                controller.prefs.update {
                    $0.sherpaModelDirectory = cleaned
                    $0.wakeWord.modelIdentifier = cleaned
                }
                Task { await controller.rebuildWakeWord() }
            }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { controller.prefs.current.wakeWord.threshold },
            set: { v in controller.prefs.update { $0.wakeWord.threshold = v } }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { Int(controller.prefs.current.webSocketPort) },
            set: { v in controller.prefs.update { $0.webSocketPort = UInt16(v) } }
        )
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { controller.prefs.current.preferredCameraUID },
            set: { v in
                if let id = v,
                   let match = state.availableCameras.first(where: { $0.id == id }) {
                    controller.camera.setPreferred(match)
                    state.preferredCameraUID = id
                    try? controller.camera.startPreview()
                } else {
                    controller.camera.setPreferred(nil)
                    state.preferredCameraUID = nil
                }
            }
        )
    }

    private var deskCameraBinding: Binding<String?> {
        Binding(
            get: { controller.prefs.current.deskCameraUID },
            set: { v in
                controller.prefs.update { $0.deskCameraUID = v }
                if let uid = v {
                    controller.camera.startSession(role: .secondary, deviceUID: uid)
                } else {
                    controller.camera.stopSession(role: .secondary)
                }
            }
        )
    }
}

// MARK: - News tab container

/// Wraps live channels and RSS feeds behind a segmented picker.
private struct NewsSettingsContainer: View {
    @Bindable var channelStore: NewsChannelStore
    let feedStore: NewsStore
    let scheduler: NewsRefreshScheduler

    private enum Section: String, CaseIterable, Identifiable {
        case liveChannels = "Live Channels"
        case rssFeeds     = "RSS Feeds"
        var id: String { rawValue }
    }

    @State private var section: Section = .liveChannels

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch section {
                case .liveChannels:
                    LiveNewsChannelsSettingsView(store: channelStore)
                case .rssFeeds:
                    NewsFeedSettingsView(store: feedStore, scheduler: scheduler)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
