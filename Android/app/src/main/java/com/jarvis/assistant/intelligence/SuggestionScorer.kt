package com.jarvis.assistant.intelligence

import android.util.Log
import com.jarvis.assistant.intelligence.model.InterruptMode
import com.jarvis.assistant.intelligence.model.RawSuggestion
import com.jarvis.assistant.intelligence.model.ScoredSuggestion
import com.jarvis.assistant.proactive.CooldownStore

/**
 * SuggestionScorer — converts [RawSuggestion] candidates from heuristics and
 * the pattern engine into [ScoredSuggestion] instances with an [InterruptMode].
 *
 * ## Score formula
 *
 *   base     = (confidence + urgency) / 2
 *   penalty  = cooldownPenalty + dismissalPenalty + speakingPenalty + drivingPenalty
 *   final    = clamp(base − penalty, 0, 1)
 *
 * ## Interrupt mode thresholds (Confidence Threshold System, system 8)
 *
 *   VOICE           final ≥ [THRESHOLD_VOICE]           (0.80)
 *   OVERLAY_ACTIVE  final ≥ [THRESHOLD_OVERLAY_ACTIVE]  (0.65)
 *   OVERLAY_PASSIVE final ≥ [THRESHOLD_OVERLAY_PASSIVE] (0.50)
 *   NONE            final <  [THRESHOLD_OVERLAY_PASSIVE]
 *
 * VOICE is only used when [voiceAllowed] = true and driving is not active.
 * If the score qualifies for VOICE but voice is off, the mode degrades to
 * OVERLAY_ACTIVE so the message is not lost.
 */
class SuggestionScorer(
    private val cooldownStore: CooldownStore,
    private val timelineStore: ContextTimelineStore,
    private val cooldownMs: Long = DEFAULT_COOLDOWN_MS,
) {

    companion object {
        private const val TAG = "SuggestionScorer"

        // ── Interrupt thresholds ──────────────────────────────────────────────
        const val THRESHOLD_VOICE           = 0.80f
        const val THRESHOLD_OVERLAY_ACTIVE  = 0.65f
        const val THRESHOLD_OVERLAY_PASSIVE = 0.50f

        // ── Penalty weights ───────────────────────────────────────────────────
        private const val DISMISSAL_PENALTY_PER_RECENT = 0.12f
        private const val MAX_DISMISSAL_PENALTY        = 0.48f
        private const val SPEAKING_PENALTY             = 0.25f
        private const val DRIVING_URGENCY_FLOOR        = 0.70f
        private const val DRIVING_PENALTY              = 0.30f
        private const val COOLDOWN_MAX_PENALTY         = 0.50f

        private val DEFAULT_COOLDOWN_MS = 30 * 60 * 1000L  // 30 min
    }

    /**
     * Score [raw] given the current device state.
     *
     * @param isDriving     True when the device is in driving mode.
     * @param isSpeaking    True when Jarvis is currently producing TTS.
     * @param voiceAllowed  When true, suggestions scoring above [THRESHOLD_VOICE]
     *                      are mapped to [InterruptMode.VOICE] rather than
     *                      [InterruptMode.OVERLAY_ACTIVE].
     */
    fun score(
        raw: RawSuggestion,
        isDriving: Boolean,
        isSpeaking: Boolean,
        voiceAllowed: Boolean = false,
    ): ScoredSuggestion {
        val base = (raw.confidence + raw.urgency) / 2f
        val penalties = mutableMapOf<String, Float>()

        // Cooldown: linear decay from full penalty immediately after surfacing
        // to zero at the edge of the cooldown window.
        val msSinceLast = cooldownStore.msSinceSurfaced(raw.dedupeKey)
        val cooldownPenalty = if (msSinceLast < cooldownMs) {
            COOLDOWN_MAX_PENALTY * (1f - msSinceLast.toFloat() / cooldownMs.toFloat())
        } else 0f
        if (cooldownPenalty > 0f) penalties["cooldown"] = cooldownPenalty

        // Dismissal history: each recent explicit dismissal costs -0.12, capped at -0.48
        val recentDismissals = timelineStore.recentDismissals(raw.dedupeKey)
        val dismissalPenalty = (recentDismissals * DISMISSAL_PENALTY_PER_RECENT)
            .coerceAtMost(MAX_DISMISSAL_PENALTY)
        if (dismissalPenalty > 0f) penalties["dismissals"] = dismissalPenalty

        // Speaking: never interrupt TTS output
        val speakingPenalty = if (isSpeaking) SPEAKING_PENALTY else 0f
        if (speakingPenalty > 0f) penalties["speaking"] = speakingPenalty

        // Driving: suppress soft nudges while driving; let high-urgency through
        val drivingPenalty = if (isDriving && raw.urgency < DRIVING_URGENCY_FLOOR)
            DRIVING_PENALTY else 0f
        if (drivingPenalty > 0f) penalties["driving"] = drivingPenalty

        val totalPenalty = cooldownPenalty + dismissalPenalty + speakingPenalty + drivingPenalty
        val finalScore = (base - totalPenalty).coerceIn(0f, 1f)

        val mode = when {
            finalScore >= THRESHOLD_VOICE && voiceAllowed && !isDriving -> InterruptMode.VOICE
            finalScore >= THRESHOLD_OVERLAY_ACTIVE                       -> InterruptMode.OVERLAY_ACTIVE
            finalScore >= THRESHOLD_OVERLAY_PASSIVE                      -> InterruptMode.OVERLAY_PASSIVE
            else                                                         -> InterruptMode.NONE
        }

        Log.v(
            TAG,
            "score(${raw.id}/${raw.dedupeKey}): " +
            "base=${"%.3f".format(base)} " +
            "penalties=${penalties.entries.joinToString { "${it.key}=${"%.3f".format(it.value)}" }} " +
            "final=${"%.3f".format(finalScore)} mode=$mode"
        )

        return ScoredSuggestion(
            raw        = raw,
            finalScore = finalScore,
            mode       = mode,
            penalties  = penalties,
        )
    }
}
