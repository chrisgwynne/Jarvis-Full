package com.jarvis.assistant.remote.macbrain

import android.util.Log
import java.util.LinkedList

/**
 * BrainCircuitBreaker — prevents repeated slow/failed Brain requests from stalling speech.
 *
 * State machine:
 *   CLOSED   → normal operation; failures accumulate.
 *   OPEN     → circuit tripped; all fetches return null immediately.
 *              After [openDurationMs] transitions to HALF_OPEN.
 *   HALF_OPEN → one probe is allowed through.
 *              Success → CLOSED (reset counters).
 *              Failure → OPEN again.
 *
 * Default policy: 5 failures within a 2-minute window trips the breaker for 5 minutes.
 */
class BrainCircuitBreaker(
    private val failureThreshold:    Int  = 5,
    private val observationWindowMs: Long = 2 * 60_000L,
    private val openDurationMs:      Long = 5 * 60_000L,
) {
    private enum class State { CLOSED, OPEN, HALF_OPEN }

    private val recentFailures = LinkedList<Long>()
    private var state          = State.CLOSED
    private var openedAtMs     = 0L

    /**
     * Returns true if the circuit is open and the request should be dropped.
     * Automatically transitions OPEN → HALF_OPEN after [openDurationMs].
     */
    @Synchronized fun isOpen(): Boolean {
        if (state == State.OPEN) {
            if (System.currentTimeMillis() - openedAtMs >= openDurationMs) {
                state = State.HALF_OPEN
                Log.d(TAG, "[BRAIN_CIRCUIT_HALF_OPEN] allowing probe")
                return false
            }
            return true
        }
        return false
    }

    /** Call on a successful Brain response. Closes the circuit if in HALF_OPEN. */
    @Synchronized fun recordSuccess() {
        if (state == State.HALF_OPEN) {
            state = State.CLOSED
            recentFailures.clear()
            Log.i(TAG, "[BRAIN_CIRCUIT_CLOSED]")
        }
    }

    /** Returns the current state name: "CLOSED" | "OPEN" | "HALF_OPEN". */
    @Synchronized fun currentState(): String = state.name

    /**
     * Resets the circuit to CLOSED, clears the failure window.
     * Called by [MacBrainStats.resetCircuit] from Settings.
     */
    @Synchronized fun reset() {
        state      = State.CLOSED
        recentFailures.clear()
        openedAtMs = 0L
        Log.i(TAG, "[BRAIN_CIRCUIT_RESET]")
    }

    /** Call on timeout, network error, or oversized response. May trip the circuit. */
    @Synchronized fun recordFailure() {
        val now = System.currentTimeMillis()
        recentFailures.add(now)
        while (recentFailures.isNotEmpty() && now - recentFailures.peek()!! > observationWindowMs) {
            recentFailures.poll()
        }
        if (state == State.HALF_OPEN || recentFailures.size >= failureThreshold) {
            state      = State.OPEN
            openedAtMs = now
            Log.w(TAG, "[BRAIN_CIRCUIT_OPEN] failures=${recentFailures.size}")
        }
    }

    companion object {
        private const val TAG = "BrainCircuitBreaker"
    }
}
