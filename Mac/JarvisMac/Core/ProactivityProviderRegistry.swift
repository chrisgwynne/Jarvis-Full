import Foundation

/// Result bundle returned by ProactivityProviderRegistry.setup().
/// Caller stores each optional strong reference to prevent deallocation.
@MainActor struct ProactivityRegistryResult {
    var todoistClient: TodoistAPIClient?
    var weatherProvider: WeatherProactivityProvider?
    var calendarProvider: CalendarProactivityProvider?
    var todoistProvider: TodoistProactivityProvider?
    var githubClient: GitHubAPIClient?
    var githubModule: GitHubModule?
    var githubProvider: GitHubProactivityProvider?
    var haProvider: HomeAssistantProactivityProvider?
    var shopifyProvider: ShopifyProactivityProvider?
    var obsidianProvider: ObsidianProactivityProvider?
}

/// Wires ProactivityEngine callbacks, news, and all proactivity providers.
/// Extracted from JarvisController.bootstrap() — Sprint O decomposition.
@MainActor enum ProactivityProviderRegistry {

    static func setup(
        engine: ProactivityEngine,
        state: AppState,
        prefs: PreferencesStore,
        overlayManager: OverlayManager,
        weatherService: WeatherService,
        calendarService: EventKitCalendarService,
        smartHome: SmartHomeClient,
        haEntityRegistry: HAEntityRegistry,
        haMotionMapper: HAMotionCameraMapper,
        obsidianVault: ObsidianVaultService,
        newsStore: NewsStore,
        newsScheduler: NewsRefreshScheduler,
        notificationQueue: NotificationQueue,
        llmRouter: LLMRouter,
        speak: @escaping (String) -> Void,
        showToast: @escaping (String, String) -> Void,
        openArticle: @escaping (NewsArticle) -> Void
    ) -> ProactivityRegistryResult {
        let breadcrumb = CrashBreadcrumbLog.shared
        var result = ProactivityRegistryResult()

        // Wire ProactivityEngine speak + overlay callbacks
        engine.onSpeak = speak
        engine.onPresent = { presentation in
            guard presentation.autoOpenOverlay else { return }
            if presentation.overlayKind == .haCamera,
               let cameraEntityID = presentation.signal.overlayPayload,
               !cameraEntityID.isEmpty {
                let displayName = haEntityRegistry.entities
                    .first(where: { $0.entityID == cameraEntityID })?.displayName
                    ?? cameraEntityID
                state.haCameraEntityID       = cameraEntityID
                state.haCameraFriendlyName   = displayName
                state.haLastAlertDescription = presentation.signal.spokenText ?? ""
            }
            overlayManager.open(presentation.overlayKind)
            if presentation.overlayKind == .news,
               let articleID = presentation.highlightItemID {
                Task {
                    if let article = await newsStore.article(id: articleID) {
                        openArticle(article)
                    }
                }
            }
        }
        engine.subscribeSystemBus()

        // Screen-error events → proactivity signals
        SystemBus.shared.subscribe(ScreenErrorDetectedEvent.self) { event in
            let signal = ProactivitySignal(
                source: .system,
                title: "Error detected in \(event.appName)",
                body: event.errorText.prefix(200).description,
                category: "screen_error",
                priority: .high,
                dedupeKey: "screen_error:\(event.appName):\(event.windowTitle)"
            )
            engine.ingest(signal, appState: state)
        }

        // News — gated by subsystemNewsEnabled
        if prefs.current.subsystemNewsEnabled {
            breadcrumb.subsystemStart("news")
            newsStore.seedDefaultFeedsIfNeeded()
            newsStore.loadFeeds()
            newsScheduler.onNewArticles = { count, source in
                let msg = "\(count) new \(count == 1 ? "story" : "stories") from \(source)"
                showToast(msg, "newspaper.fill")
                let notif = NotificationEvent(
                    priority: .passive, title: msg, body: "",
                    symbol: "newspaper.fill", category: "news")
                notificationQueue.enqueue(notif)
            }
            // Session-scoped counter: caps low/normal-priority news signals to
            // avoid flooding the proactivity tray after a long offline period.
            // High/urgent signals bypass the cap (breaking news always fires).
            // The counter is captured by the closure and lives on the heap for
            // the lifetime of the newsScheduler instance.
            var sessionPassiveNewsCount = 0
            let maxPassiveNewsPerSession = 3

            newsScheduler.onNewArticlesForProactivity = { articles in
                var overflowArticles: [NewsArticle] = []
                for article in articles {
                    let labelString = article.labels.map(\.rawValue).joined(separator: " ")
                    let isBreaking = NewsLabeller.isBreaking(title: article.title)
                        || NewsLabeller.categoryIsBreaking(labelString)
                    let priority: SignalPriority
                    if isBreaking || article.importanceScore >= 0.85 { priority = .urgent }
                    else if article.importanceScore >= 0.65               { priority = .high }
                    else if article.importanceScore >= 0.50               { priority = .normal }
                    else                                                   { priority = .low }

                    // Belt-and-suspenders cap for passive (low/normal) signals.
                    // High and urgent always deliver regardless of count.
                    let isPassive = priority < .high
                    if isPassive {
                        if sessionPassiveNewsCount >= maxPassiveNewsPerSession {
                            overflowArticles.append(article)
                            continue
                        }
                        sessionPassiveNewsCount += 1
                    }

                    // News is notification-only. Never auto-speak at startup or on refresh.
                    // User must manually open the News overlay to hear articles.
                    let spoken: String? = nil
                    let signal = ProactivitySignal(
                        source: .news,
                        title: article.title,
                        body: article.summary.isEmpty ? article.contentExcerpt : article.summary,
                        category: article.labels.first?.rawValue ?? "news",
                        priority: priority,
                        confidence: article.importanceScore,
                        expiresAt: Calendar.current.date(byAdding: .hour, value: 6, to: Date()),
                        dedupeKey: article.dedupeKey,
                        suggestedAction: "open_article",
                        spokenText: spoken,
                        requiresAttention: priority >= .high,
                        sourceArticleID: article.id
                    )
                    engine.ingest(signal, appState: state)
                }

                // Collapse overflow passive articles into one digest signal so
                // the tray shows "N more stories" rather than nothing.
                if !overflowArticles.isEmpty {
                    let count = overflowArticles.count
                    let sources = Array(Set(overflowArticles.map(\.sourceName)))
                        .sorted().prefix(3).joined(separator: ", ")
                    let body = sources.isEmpty
                        ? "Tap to browse."
                        : "From \(sources). Tap to browse."
                    let todayKey = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
                    let digest = ProactivitySignal(
                        source: .news,
                        title: "\(count) more \(count == 1 ? "story" : "stories") available",
                        body: body,
                        category: "news_digest",
                        priority: .low,
                        confidence: 0.5,
                        dedupeKey: "news_digest:\(todayKey)",
                        requiresAttention: false
                    )
                    engine.ingest(digest, appState: state)
                }
            }
            newsScheduler.start()
        } else {
            breadcrumb.subsystemSkipped("news")
        }

        // Todoist client — created here so providers can use it
        if let token = prefs.todoistAPIToken, !token.isEmpty {
            result.todoistClient = TodoistAPIClient(token: token)
        }

        // Calendar access — fire-and-forget; service handles state on response
        if prefs.current.googleCalendarEnabled {
            Task {
                let granted = await calendarService.requestAccess()
                state.log("calendar", .info, "calendar_access=\(granted)")
            }
        }

        // Weather provider
        if prefs.current.subsystemWeatherProviderEnabled {
            breadcrumb.subsystemStart("weather_provider")
            weatherService.requestAccess()
            let p = WeatherProactivityProvider(
                weatherService: weatherService, engine: engine, appState: state, prefs: prefs)
            result.weatherProvider = p
            p.start()
        } else {
            breadcrumb.subsystemSkipped("weather_provider")
        }

        // Calendar proactivity provider
        if prefs.current.subsystemCalendarProviderEnabled {
            breadcrumb.subsystemStart("calendar_provider")
            let p = CalendarProactivityProvider(
                calendarService: calendarService, engine: engine, appState: state)
            result.calendarProvider = p
            p.start()
        } else {
            breadcrumb.subsystemSkipped("calendar_provider")
        }

        // Todoist proactivity provider
        if prefs.current.subsystemTodoistProviderEnabled, let todoist = result.todoistClient {
            breadcrumb.subsystemStart("todoist_provider")
            let p = TodoistProactivityProvider(
                todoistClient: todoist, engine: engine, appState: state, prefs: prefs)
            result.todoistProvider = p
            p.start()
        } else {
            breadcrumb.subsystemSkipped("todoist_provider")
        }

        // GitHub provider (delegates to GitHubIntegrationBootstrapper)
        if let githubToken = prefs.githubPersonalAccessToken, !githubToken.isEmpty {
            breadcrumb.subsystemStart("github_provider")
            let ghResult = GitHubIntegrationBootstrapper.bootstrap(
                token: githubToken, llmRouter: llmRouter, proactivity: engine,
                appState: state, prefs: prefs)
            result.githubClient  = ghResult.client
            result.githubModule  = ghResult.module
            result.githubProvider = ghResult.proactivityProvider
        } else {
            breadcrumb.subsystemSkipped("github_provider")
        }

        // Home Assistant proactivity provider
        if prefs.current.subsystemHAProviderEnabled {
            breadcrumb.subsystemStart("ha_provider")
            Task {
                if let baseURL = prefs.current.smartHomeBaseURL, !baseURL.isEmpty,
                   let token   = prefs.current.smartHomeToken,   !token.isEmpty {
                    do {
                        let entities = try await smartHome.getStatus()
                        haEntityRegistry.sync(from: entities)
                        haMotionMapper.mappings = prefs.current.haMotionCameraMappings
                        haMotionMapper.globalCooldownSeconds = prefs.current.haGlobalAlertCooldownSeconds
                    } catch {
                        Log.app.warning("[ha-registry] Failed to sync entity states: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            let p = HomeAssistantProactivityProvider(engine: engine, appState: state, prefs: prefs)
            p.motionMapper    = haMotionMapper
            p.entityRegistry  = haEntityRegistry
            result.haProvider = p
            p.start()
        } else {
            breadcrumb.subsystemSkipped("ha_provider")
        }

        // Shopify proactivity provider
        if prefs.current.subsystemShopifyProviderEnabled,
           let shopifyToken = prefs.shopifyAccessToken, !shopifyToken.isEmpty {
            breadcrumb.subsystemStart("shopify_provider")
            let p = ShopifyProactivityProvider(engine: engine, appState: state, prefs: prefs)
            result.shopifyProvider = p
            p.start()
        } else {
            breadcrumb.subsystemSkipped("shopify_provider")
        }

        // Obsidian vault service + proactivity provider
        if prefs.current.subsystemObsidianEnabled {
            breadcrumb.subsystemStart("obsidian")
            obsidianVault.start()
            if prefs.current.obsidianProactivityEnabled {
                let p = ObsidianProactivityProvider(
                    engine: engine, appState: state, prefs: prefs, vault: obsidianVault)
                result.obsidianProvider = p
                p.start()
            }
        } else {
            breadcrumb.subsystemSkipped("obsidian")
        }

        return result
    }
}
