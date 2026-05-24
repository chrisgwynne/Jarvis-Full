package com.jarvis.assistant.intelligence

import android.content.Context
import android.content.SharedPreferences

/**
 * PatternStore — lightweight SharedPreferences-backed frequency counter for
 * time-of-day × event-key observations.
 *
 * Each observation is bucketed into a 1-hour slot (0..23).  Keys are of the
 * form `"pf_{eventKey}_{hour}"` so the total preference file remains small
 * even with many event types.
 *
 * No PII is stored — only event-kind counts per hour.  Cross-session learning
 * accumulates naturally as more ticks occur; stale data ages out implicitly
 * because recent higher-frequency slots overtake older peaks without any
 * explicit deletion.
 */
class PatternStore(context: Context) {

    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Increment the frequency counter for [eventKey] at [hour] (0–23). */
    fun recordEvent(eventKey: String, hour: Int) {
        val key = prefKey(eventKey, hour)
        val prev = prefs.getInt(key, 0)
        prefs.edit().putInt(key, prev + 1).apply()
    }

    /** Raw count for [eventKey] at [hour] (0–23). */
    fun getFrequency(eventKey: String, hour: Int): Int =
        prefs.getInt(prefKey(eventKey, hour), 0)

    /** Returns hour → count for all non-zero hours for [eventKey]. */
    fun hourlyPattern(eventKey: String): Map<Int, Int> = buildMap {
        for (h in 0..23) {
            val c = getFrequency(eventKey, h)
            if (c > 0) put(h, c)
        }
    }

    /**
     * Routine strength: ratio of top-5 hours to all hours, capped at 1.0.
     * A high value means the event is concentrated in a few consistent hours
     * (i.e. it's a routine); a low value means it's spread randomly.
     */
    fun routineStrength(eventKey: String): Float {
        val counts = hourlyPattern(eventKey).values
        if (counts.isEmpty()) return 0f
        val total = counts.sum().toFloat()
        val top5  = counts.sortedDescending().take(5).sum().toFloat()
        return (top5 / (total + 1f)).coerceIn(0f, 1f)
    }

    private fun prefKey(eventKey: String, hour: Int) = "pf_${eventKey}_$hour"

    companion object {
        const val PREFS_NAME = "jarvis_pattern_store"
    }
}
