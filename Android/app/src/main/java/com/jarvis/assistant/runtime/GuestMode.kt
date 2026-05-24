package com.jarvis.assistant.runtime

import android.util.Log

/**
 * GuestMode — process-wide guest-mode flag for time-boxed restricted use.
 *
 * When [isActive] is true:
 *   - HIGH-risk tool execution is denied (no calls, sends, payments, etc.).
 *   - MemoryWriter skips persisting conversation turns.
 *   - Contact aliasing (and any other learning surface) skips its writes.
 *
 * Activated by voice ("guest mode for 10 minutes") or Settings.  Auto-expires
 * after [activeUntilMs] passes; the next call to [isActive] notices the
 * expiry and self-clears.  No timer thread — laziness keeps it cheap.
 *
 * The flag is a plain @Volatile field, no synchronisation — single boolean,
 * single deadline, set rarely.
 */
object GuestMode {

    private const val TAG = "GuestMode"
    /** Default 10 minutes when the user doesn't specify a duration. */
    const val DEFAULT_DURATION_MS: Long = 10 * 60_000L

    @Volatile private var activeUntilMs: Long = 0L

    /** True if guest mode is enabled AND its expiry has not passed. */
    val isActive: Boolean
        get() {
            val until = activeUntilMs
            if (until == 0L) return false
            if (System.currentTimeMillis() >= until) {
                // Self-clear so subsequent reads short-circuit.
                activeUntilMs = 0L
                Log.d(TAG, "[GUEST_MODE_EXPIRED]")
                return false
            }
            return true
        }

    /** Remaining milliseconds (0 when inactive). */
    val remainingMs: Long
        get() = (activeUntilMs - System.currentTimeMillis()).coerceAtLeast(0L)

    fun enable(durationMs: Long = DEFAULT_DURATION_MS) {
        activeUntilMs = System.currentTimeMillis() + durationMs.coerceAtLeast(60_000L)
        Log.i(TAG, "[GUEST_MODE_ENABLED] durationMs=$durationMs activeUntil=$activeUntilMs")
    }

    fun disable() {
        if (activeUntilMs == 0L) return
        activeUntilMs = 0L
        Log.i(TAG, "[GUEST_MODE_DISABLED]")
    }
}
