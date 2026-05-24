# Handler Route Matrix
*Sprint R — 2026-05-22*

Documents every extracted handler: what it handles, how it is wired, and what tests exist.

---

## Intent Handlers (execute() domain delegation)

### ShopifyIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/ShopifyIntentHandler.swift` (105 lines) |
| **Extracted** | Sprint O |
| **Signature** | `func handle(_ intent: Intent) -> Bool` (sync, fires internal Tasks) |
| **Intents handled** | `.showShopifyOverlay`, `.shopifyOrders`, `.shopifyStatus`, `.shopifyRevenue`, `.shopifyFulfilment` (5 cases) |
| **Dependencies (init)** | `PreferencesStore`, `ResponseRenderer` |
| **Callbacks** | `speak`, `openOverlay` |
| **Spoken response path** | `renderer.render(ResponseKey.shopify*)` → `speak(...)` |
| **Overlay path** | `openOverlay(.shopify)` on `.showShopifyOverlay` |
| **Fallback path** | Token/domain guard → `renderer.render(ResponseKey.shopifyNotConfig)` |
| **Async behaviour** | Fires `Task { }` internally for all API calls; `handle()` itself returns sync |
| **Tests present** | None |

---

### SpotifyIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/SpotifyIntentHandler.swift` (128 lines) |
| **Extracted** | Sprint P |
| **Signature** | `func handle(_ intent: Intent) -> Bool` (sync, fires internal Tasks) |
| **Intents handled** | `.spotifyPlay`, `.spotifyPause`, `.spotifyResume`, `.spotifyNext`, `.spotifyPrevious`, `.spotifyWhatIsPlaying`, `.spotifyVolume`, `.spotifyShuffle` (8 cases) |
| **Dependencies (init)** | `PreferencesStore`, `ResponseRenderer` |
| **Lazy internal** | `private lazy var client: SpotifyAPIClient` constructed from `prefs` |
| **Callbacks** | `speak` only (no overlay) |
| **Spoken response path** | `renderer.render(ResponseKey.spotify*)` → `speak(...)` |
| **Overlay path** | None |
| **Fallback path** | Token empty guard at top of `handle()` → `spotifyNotConfig`, returns true |
| **Async behaviour** | Fires `Task { }` internally; `handle()` itself returns sync |
| **Tests present** | None |

---

### WeatherIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/WeatherIntentHandler.swift` (42 lines) |
| **Extracted** | Sprint P |
| **Signature** | `func handle(_ intent: Intent) async -> Bool` |
| **Intents handled** | `.currentWeather`, `.weatherForecast(let days)` (2 cases) |
| **Dependencies (init)** | `WeatherService`, `ResponseRenderer` |
| **Callbacks** | `speak` only |
| **Spoken response path** | `weatherService.spokenCurrentWeather()` / `spokenForecast(days:)` → `renderer.render(ResponseKey.weather*)` → `speak(...)` |
| **Overlay path** | None |
| **Fallback path** | `weatherService.isAuthorized` guard → `weatherLocationDenied` |
| **Async behaviour** | Fully `async`; called with `await` in JarvisController |
| **Tests present** | None |

---

### TodoistIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/TodoistIntentHandler.swift` (113 lines) |
| **Extracted** | Sprint P |
| **Signature** | `func handle(_ intent: Intent) async -> Bool` |
| **Intents handled** | `.showTasks`, `.whatAreMyTasks`, `.overdueTasks`, `.addTask`, `.completeTask` (5 cases, 6 enum entries — showTasks/whatAreMyTasks share a branch) |
| **Dependencies (init)** | `PreferencesStore`, `ResponseRenderer`, `storedClient: () -> TodoistAPIClient?` |
| **Callbacks** | `speak`, `setPendingContext`, `currentTranscript` |
| **Spoken response path** | `renderer.render(ResponseKey.todoist*)` → `speak(...)` |
| **Overlay path** | None (tasks shown via overlay opened separately in JarvisController) |
| **Fallback path** | Token guard → `todoistNotConfigured`; API error → `todoistTaskAddFailed` / `todoistNotConfigured` |
| **Async behaviour** | Fully `async`; called with `await` in JarvisController |
| **Follow-up** | `.addTask("")` asks clarifying question and calls `setPendingContext(.make(...))` |
| **Tests present** | None |

---

### CalendarIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/CalendarIntentHandler.swift` (94 lines) |
| **Extracted** | Sprint P |
| **Signature** | `func handle(_ intent: Intent) async -> Bool` |
| **Intents handled** | `.showCalendar`, `.nextMeeting`, `.meetingsToday`, `.addReminder` (4 cases) |
| **Dependencies (init)** | `EventKitCalendarService`, `ResponseRenderer` |
| **Callbacks** | `speak`, `setPendingContext`, `currentTranscript` |
| **Spoken response path** | `calendarService.spokenSummaryToday()` / `nextEvent()` → `renderer.render(ResponseKey.calendar*)` → `speak(...)` |
| **Overlay path** | None (calendar overlay opened separately in JarvisController before delegation) |
| **Fallback path** | `calendarService.isAuthorized` guard → `calendarNotConfigured` |
| **Async behaviour** | Fully `async`; called with `await` in JarvisController |
| **Follow-up** | `.addReminder("")` asks clarifying question via `setPendingContext(.make(...))` |
| **Tests present** | None |

---

### HomeAssistantIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/HomeAssistantIntentHandler.swift` (295 lines) |
| **Extracted** | Sprint Q |
| **Signature** | `func handle(_ intent: Intent) async -> Bool` |
| **Intents handled** | `.homeStatus`, `.homeTurnOn`, `.homeTurnOff`, `.homeQueryEntity`, `.homeSetBrightness`, `.homeSetColor`, `.homeActivateScene`, `.homeRunAutomation`, `.homeOpenCover`, `.homeCloseCover`, `.homeLock`, `.homeUnlock`, `.homeShowCamera`, `.homeShowCameraOverlay`, `.homeCloseCamera`, `.homeShowAllCameras`, `.homeMuteAlerts`, `.homeUnmuteAlerts`, `.homeIgnoreCameraForHour`, `.homeShowHADiagnostics` (20 cases) |
| **Dependencies (init)** | `HAEntityRegistry`, `HAMotionCameraMapper`, `ProactivityEngine`, `ResponseRenderer`, `AppState` |
| **Callbacks** | `speak`, `openOverlay`, `closeOverlay`, `setPendingContext`, `currentTranscript`, `getSmartHome: () -> SmartHomeClient`, `statusSummary: () async -> String`, `entityLookup: () -> [HomeEntity]` |
| **Spoken response path** | `renderer.render(ResponseKey.home*)` → `speak(...)` |
| **Overlay path** | `openOverlay(.home)` / `.article` / `.haCamera` / `.haAllCameras` / `.haDiagnostics` |
| **Fallback path** | `smartHome.isConfigured` guard → `homeNotConfigured` |
| **Async behaviour** | Fully `async`; called with `await` in JarvisController; `.homeRunAutomation` spawns an internal `Task{}` for the entity-resolve step |
| **Follow-up** | `.homeTurnOn("")` / `.homeTurnOff("")` with ambiguous entity → `.choice` pending context |
| **Tests present** | None |

---

### GitHubIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/GitHubIntentHandler.swift` (302 lines) |
| **Extracted** | Sprint Q |
| **Signature** | `func handle(_ intent: Intent) -> Bool` (sync, fires internal Tasks via `executeTask`) |
| **Intents handled** | `.showGitHubOverlay`, `.checkGitHub`, `.githubDashboard`, `.githubListPRs`, `.githubReviewPR`, `.githubOpenPR`, `.githubStalePRs`, `.githubListIssues`, `.githubStaleIssues`, `.githubCreateIssue`, `.githubRecentCommits`, `.githubChangesToday`, `.githubChangesSince`, `.githubCheckCI`, `.githubListMyRepos`, `.githubActiveRepos`, `.githubNeglectedRepos`, `.githubCreateRepo`, `.githubDescribeRepo`, `.githubProjectStatus`, `.githubCodeReview`, `.githubSummariseDiff`, `.githubLocalStats` (23 cases) |
| **Dependencies (init)** | `ResponseRenderer`, `PreferencesStore` |
| **Callbacks** | `speak`, `openOverlay`, `getModule: () -> GitHubModule?` |
| **Spoken response path** | `renderer.render(ResponseKey.github*)` → `speak(...)` (or inline string for non-keyed messages) |
| **Overlay path** | `openOverlay(.github)` for dashboard / list PRs |
| **Fallback path** | `getModule()` guard → `githubNotConfigured`; token guard in `.checkGitHub`; `GHError` catch → `githubError` |
| **Async behaviour** | `handle()` returns sync; async work wrapped in private `executeTask(_ work: @escaping (GitHubModule) async throws -> Void)` helper |
| **Tests present** | None |

---

### RedditIntentHandler
| Field | Detail |
|-------|--------|
| **File** | `Integrations/RedditIntentHandler.swift` (308 lines) |
| **Extracted** | Sprint Q |
| **Signature** | `func handle(_ intent: Intent) -> Bool` (sync, fires internal Tasks) |
| **Intents handled** | `.showReddit`, `.showRedditTop`, `.showSubreddit`, `.redditQuery`, `.redditOpenIndex`, `.redditShowComments`, `.redditOpenInBrowser`, `.redditSavePost`, `.redditSummarisePost`, `.redditSummariseComments`, `.redditRefresh` (11 cases) |
| **Dependencies (init)** | `RedditStore`, `AppState`, `LLMRouter` |
| **Callbacks** | `speak`, `openOverlay` |
| **Public surface** | `func summariseText(title:body:kind:) async -> String?` — called by `RedditOverlayView` via JarvisController bridge |
| **Backward-compat bridge** | `typealias RedditSummaryKind = RedditIntentHandler.SummaryKind` + `summariseRedditText()` forwarder on JarvisController |
| **Spoken response path** | Inline strings; LLM-generated summaries via `llmRouter.complete(req)` |
| **Overlay path** | `openOverlay(.reddit)` on most cases |
| **Fallback path** | `guard !q.isEmpty`; subreddit not found → inline message + sets `redditLastError` |
| **Async behaviour** | `handle()` returns sync; async operations (query, summarise, comments) wrapped in `Task { }` |
| **Tests present** | None |

---

## Infrastructure Handlers (non-intent, bootstrap/event-bridge role)

### LLMFallbackHandler
| Field | Detail |
|-------|--------|
| **File** | `Core/LLMFallbackHandler.swift` (300 lines) |
| **Extracted** | Sprint N |
| **Role** | Full LLM fallback pipeline: circuit guard → context assembly (memory + Obsidian RAG) → LLM routing → response handling |
| **Does NOT handle intents** | Invoked by JarvisController when deterministic routing yields `.unknown` |
| **Dependencies (init)** | `LLMRouter`, `LLMProviderCircuitBreaker`, `AppState`, `ResponseRenderer`, `ContextEngine`, `PersonalityContextBuilder`, `PreferencesStore`, `SearchService?`, `MemoryStore?`, `ObsidianVaultService`, `LatencyTracker`, `UnmatchedCommandStore` |
| **Callbacks** | `speak`, `executeIntent`, `setPendingContext`, `shouldAcknowledgeQuery`, `getPendingContext` |
| **Tests present** | None |

---

### VisionEventBridge
| Field | Detail |
|-------|--------|
| **File** | `Core/VisionEventBridge.swift` (55 lines) |
| **Extracted** | Sprint N |
| **Role** | Routes VisionModule motion/threat callbacks → ProactivityEngine signals |
| **Does NOT handle intents** | Pure event-routing; wired in JarvisController bootstrap |
| **Dependencies** | `VisionModule`, `ProactivityEngine`, `AppState` (all injected after init) |
| **Tests present** | None |

---

### RuntimeBootstrapper
| Field | Detail |
|-------|--------|
| **File** | `Core/RuntimeBootstrapper.swift` (40 lines) |
| **Extracted** | Sprint N |
| **Role** | Registers 9 subsystem shells with RuntimeCoordinator and marks ready |
| **Does NOT handle intents** | Called once during `bootstrap()` |
| **Dependencies** | `RuntimeCoordinator.shared` (global), `EventStore`, `TaskThreadEngine`, `AppState` (passed in) |
| **Tests present** | None |

---

### GitHubIntegrationBootstrapper
| Field | Detail |
|-------|--------|
| **File** | `Core/GitHubIntegrationBootstrapper.swift` (39 lines) |
| **Extracted** | Sprint N |
| **Role** | Creates `GitHubAPIClient` + `GitHubModule` + optional proactivity provider; returns them to JarvisController |
| **Does NOT handle intents** | Called once during `bootstrap()` |
| **Dependencies** | `PreferencesStore`, `ProactivityEngine`, `AppState` (all passed in) |
| **Tests present** | None |

---

### AndroidBridgeBootstrapper
| Field | Detail |
|-------|--------|
| **File** | `Core/AndroidBridgeBootstrapper.swift` (61 lines) |
| **Extracted** | Sprint O |
| **Role** | WebSocket server + Android bridge + Tailscale bootstrap wiring |
| **Does NOT handle intents** | Called once during `bootstrap()` |
| **Dependencies** | `PreferencesStore`, `AppState`, `WebSocketServer`, `ProactivityEngine` (passed in) |
| **Tests present** | None |

---

### ProactivityProviderRegistry
| Field | Detail |
|-------|--------|
| **File** | `Core/ProactivityProviderRegistry.swift` (249 lines) |
| **Extracted** | Sprint O |
| **Role** | ProactivityEngine callbacks, news wiring, all 7 proactivity providers, screen-error subscription |
| **Does NOT handle intents** | Called once during `bootstrap()` |
| **Dependencies** | `ProactivityEngine`, `AppState`, `PreferencesStore` + each integration client |
| **Tests present** | None |

---

## Handler Dispatch Summary

| Handler | Dispatch in JarvisController | Awaited? | # Intents |
|---------|------------------------------|----------|-----------|
| `ShopifyIntentHandler` | `shopifyHandler.handle(intent)` | No | 5 |
| `SpotifyIntentHandler` | `spotifyHandler.handle(intent)` | No | 8 |
| `WeatherIntentHandler` | `await weatherHandler.handle(intent)` | Yes | 2 |
| `TodoistIntentHandler` | `await todoistHandler.handle(intent)` | Yes | 5 |
| `CalendarIntentHandler` | `await calendarHandler.handle(intent)` | Yes | 4 |
| `HomeAssistantIntentHandler` | `await haIntentHandler.handle(intent)` | Yes | 20 |
| `GitHubIntentHandler` | `gitHubIntentHandler.handle(intent)` | No | 23 |
| `RedditIntentHandler` | `redditIntentHandler.handle(intent)` | No | 11 |

**Total intent cases delegated to handlers: 78**

---

## Gaps, Bridges, and Notes

### Active backward-compatibility bridges
- **`RedditSummaryKind` typealias** — `typealias RedditSummaryKind = RedditIntentHandler.SummaryKind` on JarvisController. `RedditOverlayView` calls `controller.summariseRedditText(title:body:kind:)` using `.post`/`.comments` literals. Safe to remove only when RedditOverlayView is updated to call `redditIntentHandler.summariseText` directly.
- **`summariseRedditText` forwarder** — `@discardableResult func summariseRedditText(...) async -> String?` on JarvisController forwards to `redditIntentHandler.summariseText`. Same removal condition.

### Missing tests
All 8 intent handlers have zero unit tests. Infrastructure handlers (bootstrappers, bridges) are pure wiring and are acceptably untested. Sprint R Phase 3 targets the 8 intent handlers with spy-based unit tests.

### Calendar/tasks overlay pre-delegation
`showCalendar` and `showTasks` intents call `openOverlay(.calendar)` / `openOverlay(.tasks)` in JarvisController **before** delegating to the handler. The handler only speaks the summary. This split is intentional but means the overlay is opened even if the handler returns `false` (which cannot currently happen for these intents).

### Weather intents requiring location auth
`WeatherIntentHandler` checks `weatherService.isAuthorized` synchronously. WeatherKit also requires the entitlement; without it `isAuthorized` is always `false` and both weather intents silently respond with `weatherLocationDenied`.

### HA async + internal Task pattern
`homeRunAutomation` within `HomeAssistantIntentHandler` is fully `async` at the method level but spawns an additional `Task { }` internally for the entity-resolve → service-call sequence. This allows the intent handler to return `true` immediately while the HA call proceeds. It is consistent with other HA cases but differs from the pure-await pattern used in `.homeSetBrightness`, `.homeSetColor` etc.
