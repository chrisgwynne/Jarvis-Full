import Foundation

// MARK: - ProjectKnowledgeGraph

/// Lightweight structured map of Jarvis features and their implementation state.
///
/// Seeds from hardcoded nodes derived from CLAUDE.md, then enriches each node
/// by checking whether the referenced files actually exist on disk.
/// Persisted to `project_knowledge_graph.json` to survive restarts.
@MainActor
final class ProjectKnowledgeGraph {
    static let shared = ProjectKnowledgeGraph()

    // MARK: - State

    private(set) var features: [FeatureNode] = []
    private(set) var lastEnrichedAt: Date?

    // MARK: - Disk

    private var graphURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("JarvisMac/project_knowledge_graph.json")
    }

    // MARK: - Bootstrap

    func loadOrSeed(projectRoot: URL) {
        if let loaded = loadFromDisk() {
            features = loaded
            return
        }
        features = Self.seedNodes()
        enrich(projectRoot: projectRoot)
    }

    /// Re-seeds from defaults and re-enriches. Used by the Reset button in Settings.
    func resetToSeed(projectRoot: URL) {
        features = Self.seedNodes()
        try? FileManager.default.removeItem(at: graphURL)
        enrich(projectRoot: projectRoot)
    }

    func enrich(projectRoot: URL) {
        Task.detached(priority: .utility) { [features = self.features] in
            let fm = FileManager.default

            // Sanity-check: if fewer than 10% of all listed files exist at this root,
            // the root path is wrong (e.g. DerivedData). Abort rather than corrupt
            // the seeded implementation statuses.
            let allFiles = features.flatMap { $0.files }
            if !allFiles.isEmpty {
                let hits = allFiles.filter {
                    fm.fileExists(atPath: projectRoot.appendingPathComponent($0).path)
                }.count
                guard Double(hits) / Double(allFiles.count) >= 0.10 else { return }
            }

            var enriched = features
            for i in enriched.indices {
                let existingFiles = enriched[i].files.filter { path in
                    fm.fileExists(atPath: projectRoot.appendingPathComponent(path).path)
                }
                if !existingFiles.isEmpty && enriched[i].status == .unknown {
                    enriched[i].status = .implemented
                }
                if existingFiles.isEmpty && !enriched[i].files.isEmpty
                   && enriched[i].status == .implemented {
                    enriched[i].status = .partial
                }
                enriched[i].lastUpdated = Date()
            }
            await MainActor.run {
                self.features = enriched
                self.lastEnrichedAt = Date()
                self.saveToDisk(enriched)
            }
        }
    }

    // MARK: - Project root discovery

    /// Searches common user directories for the JarvisMac Xcode project.
    /// Returns nil if not found — callers should fall back to a user-set path.
    static func findProjectRoot() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/Desktop", "\(home)/Documents", "\(home)/Developer",
            "\(home)/Projects", "\(home)/dev", "\(home)/code", home
        ]
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let candidate = "\(dir)/\(item)"
                if fm.fileExists(atPath: "\(candidate)/JarvisMac.xcodeproj") {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    // MARK: - Query

    func feature(named name: String) -> FeatureNode? {
        let lower = name.lowercased()
        return features.first { node in
            node.name.lowercased().contains(lower) ||
            node.aliases.contains(where: { $0.lowercased().contains(lower) })
        }
    }

    func features(matching query: String) -> [FeatureNode] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }
        return features.filter { node in
            let haystack = ([node.name] + node.aliases + node.files + [node.summary])
                .joined(separator: " ").lowercased()
            return words.contains(where: { haystack.contains($0) })
        }
    }

    func updateStatus(_ id: UUID, status: ImplementationStatus) {
        if let i = features.firstIndex(where: { $0.id == id }) {
            features[i].status = status
            features[i].lastUpdated = Date()
            saveToDisk(features)
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() -> [FeatureNode]? {
        guard let data = try? Data(contentsOf: graphURL),
              let decoded = try? JSONDecoder().decode([FeatureNode].self, from: data),
              !decoded.isEmpty else { return nil }
        return decoded
    }

    private func saveToDisk(_ nodes: [FeatureNode]) {
        guard let data = try? JSONEncoder().encode(nodes) else { return }
        try? FileManager.default.createDirectory(at: graphURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: graphURL, options: .atomic)
    }

    // MARK: - Seed nodes

    // swiftlint:disable function_body_length
    private static func seedNodes() -> [FeatureNode] {
        [
            FeatureNode(
                name: "Wake Word Detection",
                aliases: ["wake word", "hotword", "wakeword", "sherpa"],
                files: ["JarvisMac/Audio/WakeWordService.swift"],
                status: .implemented,
                summary: "Listens passively for the wake keyword before activating STT.",
                dependencies: ["Audio Pipeline"]
            ),
            FeatureNode(
                name: "Speech Recognition",
                aliases: ["STT", "speech-to-text", "whisper", "transcription"],
                files: ["JarvisMac/Audio/SpeechRecognizer.swift"],
                status: .implemented,
                summary: "Apple Speech and Whisper GGUF backends for voice transcription.",
                dependencies: ["Wake Word Detection"]
            ),
            FeatureNode(
                name: "Text To Speech",
                aliases: ["TTS", "voice", "piper", "speak"],
                files: ["JarvisMac/Audio/TextToSpeechService.swift", "JarvisMac/Audio/PiperTTS.swift"],
                status: .implemented,
                summary: "Apple AVSpeech and Piper ONNX local neural voice backends.",
                dependencies: []
            ),
            FeatureNode(
                name: "Persistent Conversation",
                aliases: ["conversational mode", "follow-up", "continuous listening"],
                files: ["JarvisMac/Core/ConversationRuntime.swift"],
                status: .implemented,
                summary: "10-minute conversational session with automatic STT restart after TTS.",
                dependencies: ["Speech Recognition", "Text To Speech"]
            ),
            FeatureNode(
                name: "Intent Routing",
                aliases: ["intent router", "phrase matching", "command routing"],
                files: ["JarvisMac/Core/IntentRouter.swift",
                        "JarvisMac/Phrases/CommandPhraseMatcher.swift"],
                status: .implemented,
                summary: "Tier-1 phrase store + tier-2 substring routing + LLM fallback.",
                dependencies: ["Speech Recognition"]
            ),
            FeatureNode(
                name: "LLM Integration",
                aliases: ["language model", "xai", "grok", "minimax", "gemini", "llama.cpp", "llama cpp", "local llm", "llm"],
                files: ["JarvisMac/LLM/XAIProvider.swift", "JarvisMac/Core/LLMFallbackHandler.swift"],
                status: .implemented,
                summary: "Multi-provider LLM chain: xAI → MiniMax → Gemini → llama.cpp fallback.",
                dependencies: ["Intent Routing"]
            ),
            FeatureNode(
                name: "Home Assistant Integration",
                aliases: ["smart home", "home assistant", "ha", "lights", "switches"],
                files: ["JarvisMac/Integrations/HomeAssistantRESTClient.swift",
                        "JarvisMac/Integrations/HomeAssistantWebSocketClient.swift"],
                status: .implemented,
                summary: "REST + WebSocket control of lights, switches, locks, covers, scenes.",
                dependencies: ["LLM Integration"]
            ),
            FeatureNode(
                name: "Proactivity Engine",
                aliases: ["proactivity", "proactive alerts", "signals"],
                files: ["JarvisMac/Core/ProactivityEngine.swift"],
                status: .implemented,
                summary: "Signal ingestion with cooldown, quiet hours, per-source enable/disable.",
                dependencies: ["System Bus"]
            ),
            FeatureNode(
                name: "Calendar Integration",
                aliases: ["calendar", "events", "eventkit", "reminders"],
                files: ["JarvisMac/Integrations/EventKitCalendarService.swift",
                        "JarvisMac/Integrations/CalendarProactivityProvider.swift"],
                status: .implemented,
                summary: "EventKit read/write with proactive 10-min and 1-min event alerts.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Todoist Integration",
                aliases: ["tasks", "todoist", "todo"],
                files: ["JarvisMac/Integrations/TodoistAPIClient.swift",
                        "JarvisMac/Integrations/TodoistProactivityProvider.swift"],
                status: .implemented,
                summary: "Todoist REST v2 task CRUD + morning overdue proactivity.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "GitHub Integration",
                aliases: ["github", "notifications", "pull requests", "code review"],
                files: ["JarvisMac/Integrations/GitHubAPIClient.swift",
                        "JarvisMac/UI/GitHubOverlayView.swift"],
                status: .implemented,
                summary: "GitHub notifications with review-request, mention, assignment signals.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Weather Integration",
                aliases: ["weather", "weatherkit", "forecast", "rain"],
                files: ["JarvisMac/Integrations/WeatherService.swift",
                        "JarvisMac/Integrations/WeatherProactivityProvider.swift"],
                status: .implemented,
                summary: "WeatherKit with morning briefing, severe-weather, rain proactivity.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Spotify Integration",
                aliases: ["spotify", "music", "playback"],
                files: ["JarvisMac/Integrations/SpotifyAPIClient.swift"],
                status: .implemented,
                summary: "Personal-token Spotify playback control — no OAuth server needed.",
                dependencies: []
            ),
            FeatureNode(
                name: "Shopify Integration",
                aliases: ["shopify", "orders", "revenue", "ecommerce"],
                files: ["JarvisMac/Integrations/ShopifyAPIClient.swift",
                        "JarvisMac/UI/ShopifyOverlayView.swift"],
                status: .implemented,
                summary: "Shopify Admin REST with orders, revenue, low-stock proactivity.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Obsidian Integration",
                aliases: ["obsidian", "vault", "notes", "rag", "knowledge base"],
                files: ["JarvisMac/Integrations/ObsidianVaultService.swift",
                        "JarvisMac/UI/ObsidianOverlayView.swift"],
                status: .implemented,
                summary: "Hybrid FTS+NLEmbedding vault search, RAG injection, create/append.",
                dependencies: ["LLM Integration"]
            ),
            FeatureNode(
                name: "Apple Notes Integration",
                aliases: ["apple notes", "notes app", "create note"],
                files: ["JarvisMac/Integrations/AppleNotesService.swift",
                        "JarvisMac/Integrations/NotesIntentHandler.swift"],
                status: .implemented,
                summary: "AppleScript-backed create/append/search/open for Apple Notes.",
                dependencies: []
            ),
            FeatureNode(
                name: "Apple Mail Integration",
                aliases: ["mail", "email", "inbox", "compose"],
                files: ["JarvisMac/Integrations/AppleMailService.swift",
                        "JarvisMac/Integrations/EmailIntentHandler.swift"],
                status: .implemented,
                summary: "AppleScript read/search/compose for Apple Mail with proactivity.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Camera Vision",
                aliases: ["camera", "vision", "what do you see", "describe"],
                files: ["JarvisMac/MacBridge/MacCameraService.swift"],
                status: .implemented,
                summary: "AVCaptureSession with MJPEG streaming and LLM vision analysis.",
                dependencies: ["LLM Integration"]
            ),
            FeatureNode(
                name: "Brain Memory System",
                aliases: ["brain", "long-term memory", "brain memory", "episodes"],
                files: ["JarvisMac/Brain/BrainMemoryStore.swift",
                        "JarvisMac/Brain/BrainRuntime.swift",
                        "JarvisMac/Brain/EpisodeStore.swift"],
                status: .implemented,
                summary: "Durable SQLite+semantic long-term memory with episode grouping.",
                dependencies: ["LLM Integration"]
            ),
            FeatureNode(
                name: "Semantic Memory Search",
                aliases: ["semantic search", "embedding", "similarity", "nlembedding"],
                files: ["JarvisMac/Memory/SemanticMemoryIndex.swift"],
                status: .implemented,
                summary: "NLEmbedding cosine similarity search, 500-entry cap, JSON persistence.",
                dependencies: ["Brain Memory System"]
            ),
            FeatureNode(
                name: "Context Graph",
                aliases: ["context graph", "entity graph", "focus", "project awareness"],
                files: ["JarvisMac/ContextGraph/ProjectRelationshipIndex.swift",
                        "JarvisMac/ContextGraph/ContextRanking.swift"],
                status: .implemented,
                summary: "Ranked context graph with project focus hysteresis and continuity chain.",
                dependencies: ["Brain Memory System"]
            ),
            FeatureNode(
                name: "Ambient Context Engine",
                aliases: ["ambient", "screen awareness", "active app", "window"],
                files: ["JarvisMac/Ambient/AmbientContextEngine.swift"],
                status: .implemented,
                summary: "Passive app/window tracking with watch mode and privacy filter.",
                dependencies: ["System Bus"]
            ),
            FeatureNode(
                name: "System Bus",
                aliases: ["systembus", "event bus", "pub/sub"],
                files: ["JarvisMac/Core/SystemBus.swift",
                        "JarvisMac/Core/SystemEventTypes.swift"],
                status: .implemented,
                summary: "Typed synchronous pub/sub on MainActor with 200-event ring buffer.",
                dependencies: []
            ),
            FeatureNode(
                name: "Gesture Control",
                aliases: ["gesture", "hand tracking", "hand pose", "pinch"],
                files: ["JarvisMac/SpatialInteraction/GestureClassifier.swift"],
                status: .implemented,
                summary: "VNDetectHumanHandPoseRequest gesture recognition with intent scoring.",
                dependencies: []
            ),
            FeatureNode(
                name: "Timer Service",
                aliases: ["timer", "stopwatch", "countdown"],
                files: ["JarvisMac/Core/TimerService.swift"],
                status: .implemented,
                summary: "Multiple named timers + stopwatch with expiry proactivity signals.",
                dependencies: ["Proactivity Engine"]
            ),
            FeatureNode(
                name: "Mac Brain HTTP API",
                aliases: ["brain api", "mac brain", "brain server", "android bridge"],
                files: ["JarvisMac/MacBrain/MacBrainServer.swift",
                        "JarvisMac/MacBrain/BrainHTTPHandler.swift"],
                status: .implemented,
                summary: "NWListener JSON API on port 8765 for Android Jarvis context access.",
                dependencies: ["Brain Memory System"]
            ),
            FeatureNode(
                name: "Local Learning Engine",
                aliases: ["local learning", "correction detection", "training data", "lora"],
                files: ["JarvisMac/LocalLearning/LocalLearningEngine.swift"],
                status: .implemented,
                summary: "7-store learning pipeline: aliases, corrections, routes, training export.",
                dependencies: ["Intent Routing"]
            ),
            FeatureNode(
                name: "Conversational Architecture",
                aliases: ["conversation router", "chat mode", "dialogue", "silent actions"],
                files: ["JarvisMac/Conversation/ConversationRouter.swift",
                        "JarvisMac/Conversation/ActionPolicy.swift",
                        "JarvisMac/Conversation/RollingDialogueMemory.swift"],
                status: .partial,
                summary: "Route classification and silent action execution. Dual-track not yet wired.",
                knownIssues: ["mixedChatAndCommand dual-track execution not yet wired for parallel execution"]
            ),
            FeatureNode(
                name: "Codebase Intelligence",
                aliases: ["self-knowledge", "code indexer", "self query", "what can you do"],
                files: ["JarvisMac/Intelligence/CodebaseIndexer.swift",
                        "JarvisMac/Intelligence/ProjectKnowledgeGraph.swift",
                        "JarvisMac/Intelligence/JarvisSelfQueryService.swift"],
                status: .partial,
                summary: "CodebaseIndexer + ProjectKnowledgeGraph + JarvisSelfQueryService. In progress.",
                knownIssues: ["Not yet wired into LLMFallbackHandler or JarvisController"]
            ),
        ]
    }
    // swiftlint:enable function_body_length
}
