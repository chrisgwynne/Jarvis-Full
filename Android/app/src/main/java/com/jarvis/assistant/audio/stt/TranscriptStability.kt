package com.jarvis.assistant.audio.stt

/**
 * TranscriptStability — assesses how "settled" a streaming STT partial is, so
 * the runtime can decide whether to fire deterministic local commands BEFORE
 * the final transcript arrives.
 *
 * Cuts the perceived latency of common short commands ("close spotify",
 * "open maps", "play spotify") by 200–600 ms — the difference between the
 * partial-stable point and SpeechRecognizer's final-result event.
 *
 * Inputs:
 *   - currentPartial:    the latest partial transcript
 *   - previousPartials:  recent partials in arrival order (oldest first)
 *   - confidence:        the recognizer's confidence in the current partial,
 *                        0..1 (use 0.5 when unknown)
 *   - nbestConsistency:  fraction of N-best alternatives whose top tokens
 *                        agree with the current partial, 0..1
 *
 * Output: a stability score in 0..1.  At ≥ [STABLE_THRESHOLD] callers may
 * execute a deterministic, REVERSIBLE local command on the partial without
 * waiting for the final result.
 *
 * Heuristic:
 *   - Repeated identical partials add stability (1.0 → +0.45 / 2-3 same).
 *   - High confidence directly contributes (×0.30).
 *   - N-best consistency reinforces (×0.15).
 *   - Token-tail stability — the last token hasn't kept morphing (×0.10).
 *
 * Why not use raw confidence: the platform's confidence varies wildly across
 * devices/engines.  This score is normalised by behaviour observed THIS turn,
 * which is much more reliable than absolute confidence values.
 */
object TranscriptStability {

    /**
     * Minimum score to count as "stable enough to act on".  Empirically tuned:
     * 0.82 catches the typical "close spotify" + 2 same-partial repeats with
     * mid-confidence (~0.75) before final.  Bump to 0.88 if you see false
     * starts; drop to 0.78 if you want to be more aggressive.
     */
    const val STABLE_THRESHOLD: Float = 0.82f

    fun score(
        currentPartial: String,
        previousPartials: List<String> = emptyList(),
        confidence: Float = 0.5f,
        nbestConsistency: Float = 1.0f,
    ): Float {
        val current = currentPartial.trim()
        if (current.isBlank()) return 0f

        // 1. Repeat stability: how many of the last 3 partials match the current.
        val tail = previousPartials.takeLast(3)
        val sameCount = tail.count { it.trim().equals(current, ignoreCase = true) }
        val repeatScore = when (sameCount) {
            0    -> 0f
            1    -> 0.25f
            2    -> 0.40f
            else -> 0.45f
        }

        // 2. Direct confidence weighting — clamped to [0, 1] and scaled.
        val confScore = confidence.coerceIn(0f, 1f) * 0.30f

        // 3. N-best consistency — higher when fewer alternatives disagree.
        val consistencyScore = nbestConsistency.coerceIn(0f, 1f) * 0.15f

        // 4. Token-tail stability — last token of current matches last token
        //    of the previous partial (means the recognizer has settled on the
        //    final word).  Robust to mid-utterance word substitutions.
        val tokenTailScore = computeTokenTailScore(current, previousPartials)

        return (repeatScore + confScore + consistencyScore + tokenTailScore)
            .coerceIn(0f, 1f)
    }

    private fun computeTokenTailScore(
        current: String,
        previousPartials: List<String>,
    ): Float {
        if (previousPartials.isEmpty()) return 0f
        val lastPartial = previousPartials.last().trim()
        if (lastPartial.isBlank()) return 0f
        val currTail = current.split(Regex("\\s+")).lastOrNull()?.lowercase() ?: return 0f
        val prevTail = lastPartial.split(Regex("\\s+")).lastOrNull()?.lowercase() ?: return 0f
        return if (currTail == prevTail) 0.10f else 0f
    }
}
