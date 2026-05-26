package com.jarvis.assistant.intelligence

import android.util.Log
import com.jarvis.assistant.core.events.Event
import com.jarvis.assistant.core.events.EventBus
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.intelligence.model.RawSuggestion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import java.util.Calendar

/**
 * PatternLearningEngine â€” lightweight event-driven frequency learner.
 *
 * ## What it does
 *
 * Subscribes to a curated subset of [EventBus] signals and records time-of-day
 * observations in [PatternStore].  On each intelligence tick the caller asks
 * [getSuggestions] with the current hour; the engine returns suggestions when
 * the current hour is a learned peak-frequency slot with enough confidence.
 *
 * ## Design principles
 *
 * - Deterministic and stateless in evaluation â€” no ML, no models.
 * - Confidence = clamp(frequency / THRESHOLD, 0.5, 0.75).
 * - Decay is implicit: new observations accumulate so high-frequency hours
 *   naturally supersede stale ones without explicit deletion.
 * - Accept-rate feedback from [ContextTimelineStore] adjusts the adjusted
 *   confidence so persistently-dismissed suggestions get quieter over time.
 */
class PatternLearningEngine(
    private val patternStore: PatternStore,
    private val timelineStore: ContextTimelineStore,
) {

    companion object {
        private const val TAG = "PatternLearningEngine"
        /** Minimum observations in a 1-hour slot to treat it as a pattern. */
        private const val MIN_OBSERVATIONS = 3
        /** The observed hour must be at least 1.5Ã— the per-hour average to fire. */
        private const val PEAK_RATIO = 1.5f
        /** Minimum routine strength ([PatternStore.routineStrength]) to suggest. */
        private const val MIN_ROUTINE_STRENGTH = 0.40f
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var observeJob: Job? = null

    // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    fun start() {
        if (observeJob?.isActive == true) return
        observeJob = EventBus.ofKinds(
            EventKind.FOREGROUND_APP_CHANGED,
            EventKind.DRIVING_MODE_ON,
            EventKind.BLUETOOTH_DEVICE_CONNECTED,
            EventKind.SCREEN_ON,
            EventKind.PLACE_ARRIVED,
            EventKind.LOCATION_UPDATED,
        ).onEach { event ->
            recordObservation(event)
        }.launchIn(scope)
        Log.d(TAG, "Pattern learning started")
    }

    fun stop() {
        observeJob?.cancel()
        observeJob = null
        scope.cancel()
        Log.d(TAG, "Pattern learning stopped")
    }

    // â”€â”€ Observation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    private fun recordObservation(event: Event) {
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        patternStore.recordEvent(event.kind.name.lowercase(), hour)
    }

    // â”€â”€ Suggestion generation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    /**
     * Evaluate the current [hour] against learned patterns and return any
     * suggestions whose confidence exceeds the scoring floor.
     *
     * Called by [ContextIntelligenceEngine] on each event tick.
     */
    fun getSuggestions(currentHour: Int): List<RawSuggestion> {
        val results = mutableListOf<RawSuggestion>()

        // â”€â”€ Driving routine â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        val drivingKey = EventKind.DRIVING_MODE_ON.name.lowercase()
        val drivingStrength = patternStore.routineStrength(drivingKey)
        val drivingFreq = patternStore.getFrequency(drivingKey, currentHour)
        if (drivingFreq >= MIN_OBSERVATIONS && drivingStrength >= MIN_ROUTINE_STRENGTH) {
            val pattern = patternStore.hourlyPattern(drivingKey)
            val avg = pattern.values.average().toFloat()
            if (drivingFreq >= avg * PEAK_RATIO) {
                val baseConf = (drivingFreq.toFloat() / 10f).coerceIn(0.50f, 0.72f)
                val acceptRate = timelineStore.acceptRate("pattern_driving_routine")
                // Discount confidence proportionally to how often similar nudges are dismissed
                val adjustedConf = baseConf * (0.5f + acceptRate * 0.5f)
                if (adjustedConf >= 0.38f) {
                    results.add(
                        RawSuggestion(
                            id        = "pattern_driving_routine",
                            title     = "Usual drive time",
                            message   = "You usually head out around now.",
                            confidence = adjustedConf,
                            urgency   = 0.30f,
                            dedupeKey = "pattern_driving_${currentHour}",
                        )
                    )
                    Log.v(TAG, "Driving routine suggestion at hour=$currentHour " +
                        "freq=$drivingFreq strength=${"%.2f".format(drivingStrength)} " +
                        "conf=${"%.2f".format(adjustedConf)}")
                }
            }
        }

        // â”€â”€ Morning start routine â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        if (currentHour in 5..9) {
            val screenKey = EventKind.SCREEN_ON.name.lowercase()
            val screenFreq = patternStore.getFrequency(screenKey, currentHour)
            val screenPattern = patternStore.hourlyPattern(screenKey)
            val peakHour = screenPattern.maxByOrNull { it.value }?.key ?: -1
            if (screenFreq >= MIN_OBSERVATIONS && currentHour == peakHour) {
                val baseConf = (screenFreq.toFloat() / 8f).coerceIn(0.45f, 0.65f)
                val acceptRate = timelineStore.acceptRate("pattern_morning_start")
                val adjustedConf = baseConf * (0.5f + acceptRate * 0.5f)
                if (adjustedConf >= 0.38f) {
                    results.add(
                        RawSuggestion(
                            id        = "pattern_morning_start",
                            title     = "Morning routine",
                            message   = "You usually start your day around now.",
                            confidence = adjustedConf,
                            urgency   = 0.15f,
                            dedupeKey = "pattern_morning_${currentHour}",
                        )
                    )
                    Log.v(TAG, "Morning routine suggestion at hour=$currentHour " +
                        "freq=$screenFreq conf=${"%.2f".format(adjustedConf)}")
                }
            }
        }

        return results
    }
}
