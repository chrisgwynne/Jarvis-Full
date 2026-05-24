package com.jarvis.assistant.intelligence.model

/**
 * RawSuggestion — a candidate from a [com.jarvis.assistant.intelligence.heuristics.Heuristic]
 * or the [com.jarvis.assistant.intelligence.PatternLearningEngine] before scoring.
 *
 * All numeric fields are normalised to [0, 1].
 */
data class RawSuggestion(
    /** Stable unique type identifier for this suggestion category. */
    val id: String,
    val title: String,
    val message: String,
    /** Heuristic-assigned confidence that the underlying signal is accurate [0,1]. */
    val confidence: Float,
    /** How time-sensitive this suggestion is [0,1]. */
    val urgency: Float,
    /** Optional overlay action button key. If set, an action button is shown on the card. */
    val actionKey: String? = null,
    /** Label for the action button. Required when [actionKey] is non-null. */
    val actionLabel: String? = null,
    /** Stable key for cooldown deduplication. */
    val dedupeKey: String,
    val metadata: Map<String, String> = emptyMap(),
    val createdAtMs: Long = System.currentTimeMillis(),
)
