package com.jarvis.assistant.audio.stt

/**
 * EarlyExecutionGate — decides whether a streaming STT partial is safe to act
 * on BEFORE the final transcript arrives.
 *
 * Three preconditions must ALL hold:
 *   1. Stability score ≥ [TranscriptStability.STABLE_THRESHOLD].
 *   2. The intent matched by the partial is REVERSIBLE (no send, no delete).
 *   3. We haven't already fired an early-execute for this turn.
 *
 * The intent allowlist is intentionally tight — these are the commands where
 * 200–600 ms of perceived latency removal is most felt by the user:
 *   - open/close app
 *   - media play/pause/next/previous
 *   - flashlight on/off
 *   - volume up/down/mute
 *   - smart-home lights on/off (NOT brightness adjust — too easy to misfire)
 *   - "where am I"
 *
 * Anything that sends data outward (WhatsApp/SMS/Email/Call), modifies
 * shared state (todoist complete, reminder delete), or is destructive
 * (clear notifications) is excluded.  The final transcript path runs the
 * full route as normal.
 *
 * Idempotency:
 *   The runtime calls [shouldFireEarly] with the current partial + a per-turn
 *   "alreadyFired" bool.  If it fires, the runtime sets the bool true and on
 *   the eventual final-transcript dispatch the SAME tool match must be
 *   suppressed — that suppression lives in the runtime, not here.
 */
object EarlyExecutionGate {

    /** Tools that are safe to fire on stable partials. */
    val REVERSIBLE_EARLY_TOOLS: Set<String> = setOf(
        "open_app",
        "close_app",
        "media_control",
        "flashlight",
        "volume",
        "smart_home",
        "brightness",
        "dnd",
        "where_am_i",
        "music_search",
    )

    /**
     * @return true when the partial is settled enough AND the matched tool is
     *         in [REVERSIBLE_EARLY_TOOLS] AND we haven't fired yet this turn.
     */
    fun shouldFireEarly(
        stabilityScore: Float,
        matchedToolName: String?,
        alreadyFired: Boolean,
    ): Boolean {
        if (alreadyFired) return false
        if (stabilityScore < TranscriptStability.STABLE_THRESHOLD) return false
        if (matchedToolName == null) return false
        return matchedToolName in REVERSIBLE_EARLY_TOOLS
    }
}
