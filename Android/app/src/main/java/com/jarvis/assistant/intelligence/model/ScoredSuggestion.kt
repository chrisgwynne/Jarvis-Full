package com.jarvis.assistant.intelligence.model

/**
 * InterruptMode — how a scored suggestion should be delivered.
 *
 * Thresholds (baked into [com.jarvis.assistant.intelligence.SuggestionScorer]):
 *   VOICE           ≥ 0.80 — speak aloud via TTS (reserved for high-urgency)
 *   OVERLAY_ACTIVE  ≥ 0.65 — interactive overlay card (user can tap action)
 *   OVERLAY_PASSIVE ≥ 0.50 — ambient auto-dismiss overlay card
 *   NONE            < 0.50 — suppressed; no user-facing output
 */
enum class InterruptMode {
    VOICE,
    OVERLAY_ACTIVE,
    OVERLAY_PASSIVE,
    NONE,
}

/**
 * ScoredSuggestion — a [RawSuggestion] decorated with scoring metadata.
 */
data class ScoredSuggestion(
    val raw: RawSuggestion,
    val finalScore: Float,
    val mode: InterruptMode,
    val penalties: Map<String, Float> = emptyMap(),
)
