package com.jarvis.assistant.remote.macbrain

import android.util.Log

/**
 * BrainRequestDeduper — prevents duplicate in-flight Brain fetches.
 *
 * If two pipeline turns fire nearly simultaneously (e.g. rapid barge-in followed
 * by immediate retry) and both classify to the same intent+transcript, the second
 * call is dropped rather than stacking a second network request on top of the first.
 *
 * Usage pattern (always in a try/finally):
 *   if (!deduper.tryAcquire(key)) return null
 *   try { ... } finally { deduper.release(key) }
 *
 * This only tracks in-flight requests — completed results are handled by
 * [BrainContextCache].
 */
class BrainRequestDeduper {
    private val inFlight = mutableSetOf<String>()

    /**
     * Attempts to register [key] as in-flight.
     * Returns true if the request may proceed; false if an identical request is already running.
     */
    @Synchronized fun tryAcquire(key: String): Boolean {
        if (key in inFlight) {
            Log.d(TAG, "[BRAIN_REQUEST_SKIPPED] reason=in_flight key=${key.take(40)}")
            return false
        }
        inFlight.add(key)
        return true
    }

    /** Must be called in a finally block after [tryAcquire] returns true. */
    @Synchronized fun release(key: String) {
        inFlight.remove(key)
    }

    /** Number of requests currently in-flight. */
    val inFlightCount: Int @Synchronized get() = inFlight.size

    companion object {
        private const val TAG = "BrainRequestDeduper"
    }
}
