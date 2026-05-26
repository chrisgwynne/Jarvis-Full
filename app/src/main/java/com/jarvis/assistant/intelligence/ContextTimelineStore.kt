package com.jarvis.assistant.intelligence

import com.jarvis.assistant.intelligence.model.InterruptMode
import com.jarvis.assistant.intelligence.model.ScoredSuggestion
import com.jarvis.assistant.intelligence.model.SuggestionOutcome
import com.jarvis.assistant.intelligence.model.TimelineEntry
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * ContextTimelineStore — rolling 48h / 500-entry in-memory log of every
 * suggestion dispatched by [ContextIntelligenceEngine].
 *
 * Outcome tracking enables [PatternLearningEngine] and [SuppressionEngine]
 * to adapt confidence and cooldowns based on actual user behaviour.
 *
 * Thread-safe: backed by [ConcurrentLinkedDeque].  Eviction runs inline on
 * every [record] call so the store never exceeds [maxEntries].
 */
class ContextTimelineStore(
    val maxEntries: Int = 500,
    val maxAgeMs: Long = 48 * 60 * 60 * 1000L,
) {
    private val entries = ConcurrentLinkedDeque<TimelineEntry>()

    // ── Write ─────────────────────────────────────────────────────────────────

    /**
     * Record a dispatched suggestion.  Returns the entry [TimelineEntry.id]
     * which the caller should hold to later call [resolveOutcome].
     */
    fun record(suggestion: ScoredSuggestion): String {
        val id = UUID.randomUUID().toString()
        entries.addLast(
            TimelineEntry(
                id            = id,
                dedupeKey     = suggestion.raw.dedupeKey,
                heuristicId   = suggestion.raw.id,
                title         = suggestion.raw.title,
                score         = suggestion.finalScore,
                mode          = suggestion.mode,
                dispatchedAtMs = System.currentTimeMillis(),
            )
        )
        evict()
        return id
    }

    /** Resolve the outcome for a specific entry by its id. */
    fun resolveOutcome(id: String, outcome: SuggestionOutcome) {
        entries.find { it.id == id }?.apply {
            this.outcome = outcome
            this.resolvedAtMs = System.currentTimeMillis()
        }
    }

    /**
     * Resolve the most recent unresolved entry for [dedupeKey].
     * Used by [SuppressionEngine] when the overlay fires a dismiss/accept.
     */
    fun resolveByDedupeKey(dedupeKey: String, outcome: SuggestionOutcome) {
        entries.lastOrNull {
            it.dedupeKey == dedupeKey && it.outcome == SuggestionOutcome.IGNORED
        }?.apply {
            this.outcome = outcome
            this.resolvedAtMs = System.currentTimeMillis()
        }
    }

    // ── Query ─────────────────────────────────────────────────────────────────

    fun entriesForKey(dedupeKey: String): List<TimelineEntry> =
        entries.filter { it.dedupeKey == dedupeKey }

    /**
     * Count how many times [dedupeKey] was explicitly dismissed within [withinMs].
     * Used by [SuppressionEngine] to trigger the 7-day mute after 3 dismissals.
     */
    fun recentDismissals(
        dedupeKey: String,
        withinMs: Long = 7 * 24 * 60 * 60 * 1000L,
    ): Int {
        val cutoff = System.currentTimeMillis() - withinMs
        return entries.count {
            it.dedupeKey == dedupeKey &&
                it.outcome == SuggestionOutcome.DISMISSED &&
                it.dispatchedAtMs >= cutoff
        }
    }

    /**
     * Accept rate for a heuristic id, derived from resolved entries.
     * Returns 0.5 (neutral prior) until [minSamples] verdicts are available.
     */
    fun acceptRate(heuristicId: String, minSamples: Int = 3): Float {
        val resolved = entries.filter {
            it.heuristicId == heuristicId && it.outcome != SuggestionOutcome.IGNORED
        }
        if (resolved.size < minSamples) return 0.5f
        val accepted = resolved.count { it.outcome == SuggestionOutcome.ACCEPTED }
        return accepted.toFloat() / resolved.size.toFloat()
    }

    fun allEntries(): List<TimelineEntry> = entries.toList()

    // ── Eviction ──────────────────────────────────────────────────────────────

    private fun evict() {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        while (entries.isNotEmpty() && entries.first().dispatchedAtMs < cutoff) {
            entries.removeFirst()
        }
        while (entries.size > maxEntries) {
            entries.removeFirst()
        }
    }
}
