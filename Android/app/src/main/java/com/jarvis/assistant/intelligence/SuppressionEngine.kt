package com.jarvis.assistant.intelligence

import android.util.Log
import com.jarvis.assistant.intelligence.model.SuggestionOutcome
import com.jarvis.assistant.proactive.CooldownStore

/**
 * SuppressionEngine — extended suppression layer for [ContextIntelligenceEngine].
 *
 * Augments [CooldownStore]'s per-key cooldown tracking with two extra rules:
 *
 *   1. **Repeated-dismiss mute** — once [muteThresholdDismissals] dismissals
 *      accumulate within [muteWindowMs] for a dedupe key, that key is muted
 *      in-memory for [muteDurationMs] (default 7 days).  The mute resets on
 *      process restart; for permanent suppression use
 *      [com.jarvis.assistant.core.decisions.ActionLedger.suppressClass].
 *
 *   2. **Driving suppression** — suggestions with urgency below
 *      [drivingUrgencyMin] are suppressed while the device is in driving mode.
 *      High-urgency alerts (battery critical, imminent calendar event) bypass
 *      this gate.
 */
class SuppressionEngine(
    private val cooldownStore: CooldownStore,
    private val timelineStore: ContextTimelineStore,
    val muteThresholdDismissals: Int = 3,
    val muteWindowMs: Long = 7 * 24 * 60 * 60 * 1000L,
    val muteDurationMs: Long = 7 * 24 * 60 * 60 * 1000L,
    val drivingUrgencyMin: Float = 0.70f,
) {

    companion object {
        private const val TAG = "SuppressionEngine"
    }

    // dedupeKey → epoch ms when the mute expires
    private val muteUntilMs = HashMap<String, Long>()

    // ── Query ─────────────────────────────────────────────────────────────────

    /**
     * Returns true if [dedupeKey] is currently muted (either from an active
     * timed mute or from crossing the dismiss threshold in this call).
     */
    fun isSuppressed(dedupeKey: String): Boolean {
        val now = System.currentTimeMillis()

        // Check / expire existing timed mute
        val muteUntil = muteUntilMs[dedupeKey]
        if (muteUntil != null) {
            if (now < muteUntil) {
                Log.d(TAG, "Muted: $dedupeKey (${(muteUntil - now) / 1000}s remaining)")
                return true
            } else {
                muteUntilMs.remove(dedupeKey)
            }
        }

        // Possibly activate a new mute if dismiss threshold is crossed
        val recentDismissals = timelineStore.recentDismissals(dedupeKey, muteWindowMs)
        if (recentDismissals >= muteThresholdDismissals) {
            val until = now + muteDurationMs
            muteUntilMs[dedupeKey] = until
            Log.d(TAG, "Auto-muting $dedupeKey for 7 days ($recentDismissals recent dismissals)")
            return true
        }

        return false
    }

    /**
     * Returns true when [isDriving] is active and the suggestion's [urgency]
     * is below the driving floor.  High-urgency events bypass this filter.
     */
    fun isDrivingSuppressed(isDriving: Boolean, urgency: Float): Boolean =
        isDriving && urgency < drivingUrgencyMin

    // ── Verdict recording ─────────────────────────────────────────────────────

    fun recordDismissal(dedupeKey: String) {
        cooldownStore.markIgnored(dedupeKey)
        timelineStore.resolveByDedupeKey(dedupeKey, SuggestionOutcome.DISMISSED)
        Log.d(TAG, "Dismissal recorded: $dedupeKey")
    }

    fun recordAccepted(dedupeKey: String) {
        cooldownStore.markAccepted(dedupeKey)
        timelineStore.resolveByDedupeKey(dedupeKey, SuggestionOutcome.ACCEPTED)
        Log.d(TAG, "Accepted recorded: $dedupeKey")
    }

    fun recordExpired(dedupeKey: String) {
        timelineStore.resolveByDedupeKey(dedupeKey, SuggestionOutcome.EXPIRED)
    }
}
