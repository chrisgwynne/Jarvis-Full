import Foundation

/// Development-only test harness for the ProactivityEngine.
///
/// Injects simulated signals so you can verify the full pipeline —
/// TTS spoken text, overlay appearance, deduplication, cooldowns,
/// quiet-hours, and user feedback — without waiting for a real news feed.
///
/// Usage (in JarvisController or a debug menu):
///   ProactivityTestHarness.run(engine: proactivity, appState: state)
///
/// Each scenario is labelled; check the DebugHUD "PROACTIVITY" section
/// and the Notification Tray overlay to verify each outcome.
#if DEBUG
enum ProactivityTestHarness {

    // MARK: - Test scenarios

    /// Run the full acceptance-test suite and print results to the log.
    @MainActor
    static func run(engine: ProactivityEngine, appState: AppState) {
        Log.app.info("[test_harness] *** ProactivityEngine acceptance tests starting ***")

        runBreakingNewsTest(engine: engine, appState: appState)
        runDuplicateSuppressionTest(engine: engine, appState: appState)
        runLowPriorityTest(engine: engine, appState: appState)
        runCooldownTest(engine: engine, appState: appState)
        runMutedSourceTest(engine: engine, appState: appState)
        runNormalPriorityTest(engine: engine, appState: appState)
        runUserSuppressionTest(engine: engine, appState: appState)

        Log.app.info("[test_harness] *** All simulated signals injected — check Debug HUD and Notification Tray ***")
    }

    // MARK: - Individual scenarios

    /// TC-1: Breaking news → engine should speak immediately.
    @MainActor
    static func runBreakingNewsTest(engine: ProactivityEngine, appState: AppState) {
        let signal = ProactivitySignal(
            id: "test-breaking-\(UUID().uuidString)",
            source: .news,
            title: "BREAKING: Major earthquake strikes Pacific coast",
            body: "Magnitude 7.8 earthquake has struck off the coast. Tsunami warnings issued.",
            category: "world",
            priority: .urgent,
            confidence: 0.95,
            dedupeKey: "test-breaking-earthquake-pacific-\(Date().timeIntervalSince1970)",
            suggestedAction: "open_article",
            spokenText: "Breaking news: Major earthquake strikes Pacific coast. Tsunami warnings issued.",
            requiresAttention: true
        )
        engine.ingest(signal, appState: appState)
        assert(engine.pendingSignals.first?.id == signal.id || engine.pendingSignals.contains { $0.id == signal.id },
               "TC-1 FAIL: Breaking news signal not added to pending")
        Log.app.info("[test_harness] TC-1 breaking_news: decision=\(engine.lastDecision.rawValue, privacy: .public)")
    }

    /// TC-2: Same dedupeKey → second ingest should be ignored.
    @MainActor
    static func runDuplicateSuppressionTest(engine: ProactivityEngine, appState: AppState) {
        let key = "test-dedupe-stable-key"
        let s1 = ProactivitySignal(
            id: "test-dedupe-1",
            source: .news,
            title: "Story that will be deduped",
            body: "",
            priority: .urgent,
            dedupeKey: key,
            spokenText: "Dedupe test signal."
        )
        let s2 = ProactivitySignal(
            id: "test-dedupe-2",
            source: .news,
            title: "Story that will be deduped — second arrival",
            body: "",
            priority: .urgent,
            dedupeKey: key,
            spokenText: "This should NOT be spoken."
        )
        let countBefore = engine.pendingSignals.count
        engine.ingest(s1, appState: appState)
        engine.ingest(s2, appState: appState)
        let countAfter = engine.pendingSignals.count
        // s2 should be ignored (same dedupeKey).
        let s2Pending = engine.pendingSignals.contains { $0.id == "test-dedupe-2" }
        if s2Pending {
            Log.app.warning("[test_harness] TC-2 FAIL: duplicate signal was added to pending (count before=\(countBefore, privacy: .public) after=\(countAfter, privacy: .public))")
        } else {
            Log.app.info("[test_harness] TC-2 dedupe_suppression: PASS — duplicate ignored")
        }
    }

    /// TC-3: Low priority → should log only, not added to pending.
    @MainActor
    static func runLowPriorityTest(engine: ProactivityEngine, appState: AppState) {
        let signal = ProactivitySignal(
            id: "test-low-priority-\(UUID().uuidString)",
            source: .news,
            title: "Mild interest story that nobody needs to hear about right now",
            body: "Very low importance event.",
            priority: .low,
            confidence: 0.3,
            dedupeKey: "test-low-\(UUID().uuidString)"
        )
        let countBefore = engine.pendingSignals.count
        engine.ingest(signal, appState: appState)
        let added = engine.pendingSignals.count > countBefore
        if added {
            Log.app.warning("[test_harness] TC-3 FAIL: low priority signal was added to pending")
        } else {
            Log.app.info("[test_harness] TC-3 low_priority: PASS — logged only, not added to pending")
        }
    }

    /// TC-4: Cooldown — inject two signals from the same source quickly;
    ///        second should be showQuietly rather than speakNow.
    @MainActor
    static func runCooldownTest(engine: ProactivityEngine, appState: AppState) {
        // First signal speaks; immediately inject a second — cooldown not yet expired.
        let s1 = ProactivitySignal(
            id: "test-cooldown-1",
            source: .system,
            title: "System alert: Disk space low",
            body: "",
            priority: .urgent,
            dedupeKey: "test-cooldown-disk-1",
            spokenText: "Warning: disk space is low."
        )
        let s2 = ProactivitySignal(
            id: "test-cooldown-2",
            source: .system,
            title: "System alert: CPU usage high",
            body: "",
            priority: .urgent,
            dedupeKey: "test-cooldown-cpu-2",
            spokenText: "Should be queued, not spoken, due to cooldown."
        )
        engine.ingest(s1, appState: appState)
        engine.ingest(s2, appState: appState)
        Log.app.info("[test_harness] TC-4 cooldown: s1 decision=\(engine.lastDecision.rawValue, privacy: .public) — check s2 was 'show_quietly' not 'speak_now'")
    }

    /// TC-5: Muted source — signal from a muted source should be logOnly.
    @MainActor
    static func runMutedSourceTest(engine: ProactivityEngine, appState: AppState) {
        engine.mute(.shopify, for: 3600)
        let signal = ProactivitySignal(
            id: "test-muted-shopify-\(UUID().uuidString)",
            source: .shopify,
            title: "New Shopify order: £120",
            body: "",
            priority: .high,
            dedupeKey: "test-muted-shopify-\(UUID().uuidString)",
            spokenText: "New order received."
        )
        let countBefore = engine.pendingSignals.count
        engine.ingest(signal, appState: appState)
        let added = engine.pendingSignals.count > countBefore
        if added {
            Log.app.warning("[test_harness] TC-5 FAIL: signal from muted source was added to pending")
        } else {
            Log.app.info("[test_harness] TC-5 muted_source: PASS — muted source signal was suppressed")
        }
        // Unmute after test.
        engine.unmute(.shopify)
    }

    /// TC-6: Normal priority → show quietly in tray, no speech.
    @MainActor
    static func runNormalPriorityTest(engine: ProactivityEngine, appState: AppState) {
        let signal = ProactivitySignal(
            id: "test-normal-\(UUID().uuidString)",
            source: .news,
            title: "Tech company posts quarterly earnings",
            body: "Revenue up 8% year-on-year.",
            priority: .normal,
            dedupeKey: "test-normal-earnings-\(UUID().uuidString)"
        )
        engine.ingest(signal, appState: appState)
        Log.app.info("[test_harness] TC-6 normal_priority: decision=\(engine.lastDecision.rawValue, privacy: .public) — expected 'show_quietly'")
    }

    /// TC-7: User suppression — after neverTellAboutThis(), same category is suppressed.
    @MainActor
    static func runUserSuppressionTest(engine: ProactivityEngine, appState: AppState) {
        // First inject a signal so lastSpokenSignal is set.
        let s1 = ProactivitySignal(
            id: "test-suppress-seed-\(UUID().uuidString)",
            source: .news,
            title: "Sports results: Team wins championship",
            body: "",
            category: "sports",
            priority: .urgent,
            dedupeKey: "test-suppress-seed-\(UUID().uuidString)",
            spokenText: "Sports result signal."
        )
        engine.ingest(s1, appState: appState)
        engine.neverTellAboutThis()

        // Now inject another signal with same source+category.
        let s2 = ProactivitySignal(
            id: "test-suppress-check-\(UUID().uuidString)",
            source: .news,
            title: "More sports news",
            body: "",
            category: "sports",
            priority: .urgent,
            dedupeKey: "test-suppress-sports-2-\(UUID().uuidString)",
            spokenText: "Should be suppressed."
        )
        let countBefore = engine.pendingSignals.count
        engine.ingest(s2, appState: appState)
        let added = engine.pendingSignals.count > countBefore
        if added {
            Log.app.warning("[test_harness] TC-7 FAIL: suppressed category signal was added to pending")
        } else {
            Log.app.info("[test_harness] TC-7 user_suppression: PASS — suppressed category was ignored")
        }
        // Clean up suppression so it doesn't affect real usage.
        engine.preferences.suppressedKeys.remove("news::sports")
    }

    // MARK: - Individual quick signals (use from debug menu)

    /// Inject a single breaking news signal — useful for rapid manual testing.
    @MainActor
    static func injectBreakingNews(
        headline: String = "Breaking: AI lab announces GPT-6",
        source: String = "TechCrunch",
        engine: ProactivityEngine,
        appState: AppState
    ) {
        let signal = ProactivitySignal(
            id: UUID().uuidString,
            source: .news,
            title: headline,
            body: "Full details emerging. Check the news overlay for more.",
            category: "ai",
            priority: .urgent,
            confidence: 0.92,
            dedupeKey: "manual-inject-\(headline.lowercased().prefix(40))",
            suggestedAction: "open_article",
            spokenText: "Breaking news from \(source): \(headline).",
            requiresAttention: true
        )
        engine.ingest(signal, appState: appState)
    }

    /// Inject a high-priority (non-breaking) signal to test tray + spoken summary.
    @MainActor
    static func injectHighPriorityStory(
        headline: String = "Apple announces major iPhone overhaul",
        engine: ProactivityEngine,
        appState: AppState
    ) {
        let signal = ProactivitySignal(
            id: UUID().uuidString,
            source: .news,
            title: headline,
            body: "",
            category: "technology",
            priority: .high,
            confidence: 0.78,
            dedupeKey: "manual-high-\(headline.lowercased().prefix(40))",
            suggestedAction: "open_article",
            spokenText: "Important technology story: \(headline).",
            requiresAttention: true
        )
        engine.ingest(signal, appState: appState)
    }

    /// Inject a quiet / normal-priority signal to verify tray-only behaviour.
    @MainActor
    static func injectQuietSignal(engine: ProactivityEngine, appState: AppState) {
        let signal = ProactivitySignal(
            id: UUID().uuidString,
            source: .news,
            title: "Minor market movement in European stocks",
            body: "",
            priority: .normal,
            dedupeKey: "manual-quiet-\(UUID().uuidString)"
        )
        engine.ingest(signal, appState: appState)
    }
}
#endif

/*
 ┌──────────────────────────────────────────────────────────────────────┐
 │  MANUAL TEST CHECKLIST — Proactivity Engine Sprint                   │
 ├──────────────────────────────────────────────────────────────────────┤
 │                                                                      │
 │  Prerequisites: build clean, run on macOS, open Debug HUD (⌘⇧D).    │
 │                                                                      │
 │  NEWS SIGNAL FLOW                                                    │
 │  ─────────────────                                                   │
 │  □ "Jarvis, refresh news" — check scheduler fires                   │
 │  □ Injected breaking signal: Jarvis speaks headline                  │
 │  □ Notification tray shows the signal row                           │
 │  □ Second injection with SAME dedupeKey → no speech, no duplicate   │
 │  □ "open that story" → news overlay opens with article              │
 │  □ "summarise that" → Jarvis speaks excerpt                         │
 │  □ "mute news for an hour" → news stays silent for 60 min           │
 │                                                                      │
 │  POLICY RULES                                                        │
 │  ────────────                                                        │
 │  □ Low-priority signal: no speech, not in tray                      │
 │  □ Urgent signal (engine idle): Jarvis speaks                       │
 │  □ Muted source (.news): signal silently dropped                    │
 │  □ Cooldown: second rapid signal shows in tray but not spoken       │
 │                                                                      │
 │  QUEUE BEHAVIOUR                                                     │
 │  ────────────────                                                    │
 │  □ While Jarvis is speaking: inject urgent signal → queued          │
 │  □ After speech ends: if still unspoken, check DebugHUD pending ≥ 1 │
 │                                                                      │
 │  FEEDBACK LOOP                                                       │
 │  ──────────────                                                      │
 │  □ "that was useful" → DebugHUD shows positive feedback count        │
 │  □ "not useful" 3× → source+category auto-suppressed                │
 │  □ "don't tell me about this" → category suppressed immediately     │
 │  □ "always tell me about this" → category boosted                   │
 │                                                                      │
 │  NOTIFICATION TRAY                                                   │
 │  ──────────────────                                                  │
 │  □ "what needs my attention" → tray opens, count announced          │
 │  □ Source filter chips work                                         │
 │  □ Dismiss single row → removed from list                           │
 │  □ "clear notifications" → all dismissed, tray empties              │
 │  □ "open that story" button in row → article opens                  │
 │                                                                      │
 │  PROACTIVITY CONTROLS                                                │
 │  ─────────────────────                                               │
 │  □ "pause proactivity" → engine.isPaused = true (DebugHUD)          │
 │  □ Inject signal while paused → log only                            │
 │  □ "resume proactivity" → signals flow again                        │
 │  □ Quiet hours: set quietHoursStart to now, inject normal → queued  │
 │                                                                      │
 │  SETTINGS                                                            │
 │  ────────                                                            │
 │  □ proactivityEngine.settings.newsEnabled = false → no news signals │
 │  □ breakingNewsOnly = true → normal signals suppressed              │
 │  □ minimumPriority = .urgent → high signals suppressed              │
 │                                                                      │
 │  REGRESSION                                                          │
 │  ──────────                                                          │
 │  □ Wake word still triggers after harness run                       │
 │  □ Normal commands ("what time is it") still work                   │
 │  □ News overlay still opens via "show news"                         │
 │  □ Memory commands still work                                        │
 │  □ No crash after 10+ rapid signal injections                       │
 │                                                                      │
 │  TO RUN AUTOMATED TESTS:                                             │
 │  ProactivityTestHarness.run(engine: controller.proactivity,         │
 │                             appState: controller.state)              │
 │                                                                      │
 │  Check system log: filter on "[test_harness]" subsystem.            │
 └──────────────────────────────────────────────────────────────────────┘
*/
