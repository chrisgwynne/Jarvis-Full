package com.jarvis.assistant.intelligence.model

/**
 * SuggestionOutcome — the resolved fate of a dispatched suggestion.
 *
 * Used by [com.jarvis.assistant.intelligence.ContextTimelineStore] and consumed
 * by [com.jarvis.assistant.intelligence.PatternLearningEngine] to adapt confidence.
 */
enum class SuggestionOutcome {
    /** User tapped the action button or voice-confirmed. */
    ACCEPTED,
    /** User tapped the dismiss (×) button. */
    DISMISSED,
    /** Card auto-dismissed with no interaction. */
    EXPIRED,
    /** Verdict window elapsed without any signal — default initial state. */
    IGNORED,
}

/**
 * TimelineEntry — one record in [com.jarvis.assistant.intelligence.ContextTimelineStore].
 *
 * Mutable outcome fields are intentionally `var` so the store can resolve
 * them in-place without replacing the entry.
 */
data class TimelineEntry(
    val id: String,
    val dedupeKey: String,
    val heuristicId: String,
    val title: String,
    val score: Float,
    val mode: InterruptMode,
    val dispatchedAtMs: Long,
    var outcome: SuggestionOutcome = SuggestionOutcome.IGNORED,
    var resolvedAtMs: Long? = null,
)
