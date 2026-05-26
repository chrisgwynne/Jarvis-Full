package com.jarvis.assistant.intelligence

import android.util.Log
import com.jarvis.assistant.core.events.Event
import com.jarvis.assistant.core.events.EventBus
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.intelligence.heuristics.BehaviouralHeuristicsRegistry
import com.jarvis.assistant.intelligence.model.InterruptMode
import com.jarvis.assistant.intelligence.model.RawSuggestion
import com.jarvis.assistant.intelligence.model.ScoredSuggestion
import com.jarvis.assistant.overlay.OverlayEventBridge
import com.jarvis.assistant.overlay.model.OverlayAction
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import com.jarvis.assistant.overlay.model.OverlayPriority
import com.jarvis.assistant.proactive.ContextSnapshot
import com.jarvis.assistant.proactive.CooldownStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import java.util.ArrayDeque
import java.util.Calendar

/**
 * ContextIntelligenceEngine â€” event-driven orchestrator for the Proactive
 * Intelligence system.
 *
 * ## Architecture
 *
 * Unlike [com.jarvis.assistant.proactive.ProactiveEngine] which polls every
 * 60 s, this engine is **event-driven**: it wakes immediately when any
 * relevant [EventBus] signal arrives.
 *
 * On each wake:
 *   1. Build a context window from the last [CONTEXT_WINDOW_MS] of events.
 *   2. Run every registered [BehaviouralHeuristicsRegistry] heuristic.
 *   3. Ask [PatternLearningEngine] for pattern-based suggestions.
 *   4. Score all candidates with [SuggestionScorer].
 *   5. Apply [SuppressionEngine] gates (cooldown, dismissal mute, driving).
 *   6. Dispatch the winner via [OverlayEventBridge].
 *   7. Record in [ContextTimelineStore] for future adaptation.
 *
 * ## Relation to ProactiveEngine
 *
 * The two engines run in parallel.  ProactiveEngine owns TTS/notification
 * delivery for scheduled reminders, calendar, and missed calls.  This engine
 * focuses on contextual, heuristic-driven overlay suggestions that require
 * immediate reaction to EventBus signals.
 *
 * @param cooldownStore     Shared with ProactiveEngine so one surfacing
 *                          suppresses the other.
 * @param snapshotProvider  Lambda returning ProactiveEngine.lastSnapshot.
 * @param isDrivingProvider Lambda returning the current driving state.
 * @param voiceAllowed      When true, VOICE-mode suggestions are flagged for
 *                          spoken delivery.
 * @param patternStore      Optional pattern store; pattern learning is disabled
 *                          when null (useful for tests).
 */
class ContextIntelligenceEngine(
    private val cooldownStore: CooldownStore,
    private val snapshotProvider: () -> ContextSnapshot?,
    private val isDrivingProvider: () -> Boolean = { false },
    private val voiceAllowed: Boolean = false,
    private val registry: BehaviouralHeuristicsRegistry = BehaviouralHeuristicsRegistry(),
    val timelineStore: ContextTimelineStore = ContextTimelineStore(),
    patternStore: PatternStore? = null,
) {

    companion object {
        private const val TAG = "ContextIntelligenceEngine"
        /** Events older than this are excluded from the context window. */
        private val CONTEXT_WINDOW_MS = 10 * 60_000L
        private const val CONTEXT_WINDOW_MAX = 200
        /** Minimum ms between any two intelligence dispatches (global gap). */
        private val GLOBAL_GAP_MS = 90_000L
    }

    // â”€â”€ Components â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private val scorer      = SuggestionScorer(cooldownStore, timelineStore)
    val suppression         = SuppressionEngine(cooldownStore, timelineStore)
    private val patLearning = patternStore?.let { PatternLearningEngine(it, timelineStore) }

    // â”€â”€ Event context window â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private val contextWindow = ArrayDeque<Event>(CONTEXT_WINDOW_MAX)
    private val windowLock    = Any()

    private fun addToWindow(event: Event) = synchronized(windowLock) {
        contextWindow.addLast(event)
        val cutoff = System.currentTimeMillis() - CONTEXT_WINDOW_MS
        while (contextWindow.isNotEmpty() && (contextWindow.peekFirst()?.tsMillis ?: Long.MAX_VALUE) < cutoff) {
            contextWindow.removeFirst()
        }
        while (contextWindow.size > CONTEXT_WINDOW_MAX) contextWindow.removeFirst()
    }

    private fun windowSnapshot(): List<Event> = synchronized(windowLock) { contextWindow.toList() }

    // â”€â”€ Global gap â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    @Volatile private var lastDispatchMs: Long = Long.MIN_VALUE

    // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private val scope    = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var eventJob: Job? = null

    fun start() {
        if (eventJob?.isActive == true) return

        patLearning?.start()

        // Subscribe to every EventBus event: add to window + trigger evaluation
        // for the kinds that carry intelligence-relevant signals.
        eventJob = EventBus.events.onEach { event ->
            addToWindow(event)
            if (event.kind in TRIGGER_KINDS) {
                evaluate()
            }
        }.launchIn(scope)

        Log.d(TAG, "Started")
    }

    fun stop() {
        patLearning?.stop()
        eventJob?.cancel()
        eventJob = null
        scope.cancel()
        Log.d(TAG, "Stopped")
    }

    // â”€â”€ Trigger kinds â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private val TRIGGER_KINDS: Set<EventKind> = setOf(
        EventKind.FOREGROUND_APP_CHANGED,
        EventKind.DRIVING_MODE_ON,
        EventKind.BLUETOOTH_DEVICE_CONNECTED,
        EventKind.BATTERY_LOW,
        EventKind.BATTERY_CHANGED,
        EventKind.SMART_HOME_STATE,
        EventKind.TOOL_EXECUTED,
        EventKind.PLACE_ARRIVED,
        EventKind.PLACE_LEFT,
        EventKind.NOTIFICATION_POSTED,
        EventKind.MEETING_IMMINENT,
        EventKind.SCREEN_ON,
    )

    // â”€â”€ Core evaluation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private fun evaluate() {
        val snapshot   = snapshotProvider()
        val events     = windowSnapshot()
        val isDriving  = isDrivingProvider()
        val isSpeaking = snapshot?.isJarvisSpeaking ?: false

        // Heuristic candidates
        val heuristicCandidates = registry.heuristics.mapNotNull { h ->
            try {
                h.evaluate(events, snapshot)
            } catch (e: Exception) {
                Log.w(TAG, "Heuristic ${h.id} threw: ${e.message}")
                null
            }
        }

        // Pattern-based candidates
        val currentHour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        val patternCandidates = patLearning?.getSuggestions(currentHour) ?: emptyList()

        val allCandidates: List<RawSuggestion> = heuristicCandidates + patternCandidates
        if (allCandidates.isEmpty()) return

        // Score and filter
        val scored = allCandidates
            .map { raw -> scorer.score(raw, isDriving, isSpeaking, voiceAllowed) }
            .filter { it.mode != InterruptMode.NONE }

        if (scored.isEmpty()) return

        val winner = scored.maxByOrNull { it.finalScore } ?: return

        // Global gap
        val now = System.currentTimeMillis()
        if (lastDispatchMs != Long.MIN_VALUE && (now - lastDispatchMs) < GLOBAL_GAP_MS) {
            Log.v(TAG, "Global gap not satisfied â€” suppressing ${winner.raw.id}")
            return
        }

        // Suppression gates
        if (suppression.isSuppressed(winner.raw.dedupeKey)) return
        if (suppression.isDrivingSuppressed(isDriving, winner.raw.urgency)) return

        dispatch(winner)
    }

    // â”€â”€ Dispatch â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private fun dispatch(scored: ScoredSuggestion) {
        val raw = scored.raw
        lastDispatchMs = System.currentTimeMillis()
        timelineStore.record(scored)
        cooldownStore.markSurfaced(raw.dedupeKey)

        Log.d(TAG, "Dispatch ${raw.id}/${raw.dedupeKey} " +
            "mode=${scored.mode} score=${"%.3f".format(scored.finalScore)}")

        val priority = if (scored.mode == InterruptMode.OVERLAY_PASSIVE)
            OverlayPriority.NORMAL else OverlayPriority.HIGH

        showOverlay(scored, priority)
    }

    private fun showOverlay(scored: ScoredSuggestion, priority: OverlayPriority) {
        val raw       = scored.raw
        val acceptKey = raw.actionKey

        // Dismiss: record dismissal for suppression adaptation
        val dismissKey = "intel_dismiss_${raw.dedupeKey}"
        OverlayEventBridge.onAction(dismissKey) {
            suppression.recordDismissal(raw.dedupeKey)
            OverlayEventBridge.clearAction(dismissKey)
        }

        // Accept: record acceptance if an action button is wired
        if (acceptKey != null) {
            OverlayEventBridge.onAction(acceptKey) {
                suppression.recordAccepted(raw.dedupeKey)
                OverlayEventBridge.clearAction(acceptKey)
            }
        }

        val actions = buildList {
            if (acceptKey != null && raw.actionLabel != null) {
                add(OverlayAction(actionKey = acceptKey, label = raw.actionLabel, isPrimary = true))
            }
        }

        OverlayEventBridge.show(
            OverlayCard(
                type     = OverlayCardType.PROACTIVE_PROMPT,
                title    = raw.title,
                message  = raw.message,
                actions  = actions,
                dedupKey = raw.dedupeKey,
                priority = priority,
            )
        )
    }
}
