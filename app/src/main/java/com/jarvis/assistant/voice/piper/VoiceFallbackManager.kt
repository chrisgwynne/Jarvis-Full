package com.jarvis.assistant.voice.piper

import android.util.Log

/**
 * VoiceFallbackManager — failure counter + exponential cooldown for the
 * Piper voice path.
 *
 * Goal: never repeatedly retry a broken model on every utterance.  Each
 * Piper failure increments the counter; the next [allowAttempt] call
 * succeeds only after a wait that doubles each time, capped at
 * [MAX_COOLDOWN_MS].  After [MAX_FAILURES] consecutive failures we trip
 * permanently for the rest of the process — the user can re-enable from
 * the Settings > Voice Diagnostics screen.
 *
 * A single [recordSuccess] resets the counter.
 *
 * Thread-safe via @Volatile + synchronized blocks.  Cheap; single
 * instance per process.
 */
class VoiceFallbackManager {

    companion object {
        private const val TAG = "VoiceFallbackManager"

        /** First cooldown after one failure (5 s).  Doubles per failure. */
        const val INITIAL_COOLDOWN_MS: Long = 5_000L
        /** Hard ceiling — never wait more than 5 minutes between attempts. */
        const val MAX_COOLDOWN_MS: Long     = 5 * 60_000L
        /** After this many failures, stop retrying until manually reset. */
        const val MAX_FAILURES: Int         = 5
    }

    @Volatile private var failures: Int     = 0
    @Volatile private var blockedUntilMs: Long = 0L
    @Volatile private var permanentlyTripped: Boolean = false
    @Volatile private var lastFailureReason: String   = ""

    /** True when Piper is currently disabled by the fallback policy. */
    val isFallbackActive: Boolean
        get() = permanentlyTripped ||
            (System.currentTimeMillis() < blockedUntilMs)

    val failureCount: Int      get() = failures
    val lastReason: String     get() = lastFailureReason
    val isPermanentlyTripped: Boolean get() = permanentlyTripped

    /**
     * @return true if the caller may attempt a Piper synthesis now;
     *         false if the cooldown is still in effect or we've tripped.
     */
    @Synchronized
    fun allowAttempt(): Boolean {
        if (permanentlyTripped) return false
        return System.currentTimeMillis() >= blockedUntilMs
    }

    /**
     * Record a Piper failure with [reason] (operator-facing, no PII).
     * Increments the counter, schedules the next cooldown, and trips
     * permanently after [MAX_FAILURES].
     */
    @Synchronized
    fun recordFailure(reason: String) {
        if (permanentlyTripped) return
        failures++
        lastFailureReason = reason
        // Exponential backoff: 5s, 10s, 20s, 40s, 80s, …, capped.
        val cooldown = (INITIAL_COOLDOWN_MS shl (failures - 1).coerceAtMost(20))
            .coerceAtMost(MAX_COOLDOWN_MS)
        blockedUntilMs = System.currentTimeMillis() + cooldown
        if (failures >= MAX_FAILURES) {
            permanentlyTripped = true
            Log.w(TAG, "[PIPER_FALLBACK_TRIPPED_PERMANENTLY] failures=$failures " +
                "lastReason=\"$reason\"")
        } else {
            Log.w(TAG, "[PIPER_FALLBACK_COOLDOWN] failures=$failures " +
                "cooldownMs=$cooldown reason=\"$reason\"")
        }
        PiperDiagnostics.update {
            it.copy(
                fallbackActive          = isFallbackActive,
                failureCount            = failures,
                lastInferenceFailReason = reason,
            )
        }
    }

    /** Reset to clean state — counter to 0, cooldown cleared, trip released. */
    @Synchronized
    fun recordSuccess() {
        if (failures == 0 && !permanentlyTripped) return
        Log.d(TAG, "[PIPER_FALLBACK_CLEARED] previous_failures=$failures")
        failures = 0
        blockedUntilMs = 0L
        permanentlyTripped = false
        lastFailureReason = ""
        PiperDiagnostics.update {
            it.copy(fallbackActive = false, failureCount = 0)
        }
    }

    /** Manual override from Settings — clears the trip without a successful synth. */
    @Synchronized
    fun manualReset() {
        Log.d(TAG, "[PIPER_FALLBACK_MANUAL_RESET]")
        failures = 0
        blockedUntilMs = 0L
        permanentlyTripped = false
        lastFailureReason = ""
        PiperDiagnostics.update {
            it.copy(fallbackActive = false, failureCount = 0, lastInferenceFailReason = "")
        }
    }
}
