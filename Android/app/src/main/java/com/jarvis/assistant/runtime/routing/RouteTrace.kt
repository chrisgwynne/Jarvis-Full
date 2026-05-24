package com.jarvis.assistant.runtime.routing

import android.util.Log

/**
 * RouteTrace — per-turn ordered trail of every routing phase the runtime
 * walked through, with elapsed time per step.
 *
 * Replaces the scattered `[ROUTE_*]`, `[PHASE_*]`, `[TOOL_*]` logs sprinkled
 * through JarvisRuntime with one structured record per turn.  At the end of
 * routing the runtime calls [emit] and a single concise line lands in logcat:
 *
 *   [ROUTE_TRACE] turn=abc12 transcript="close spotify"
 *     pending(skip)+1ms → todoist-complete(skip)+3ms → instant(skip)+4ms
 *     → tool-match(close_app)+7ms → dispatch(done)+38ms total=42ms
 *
 * Cheap: a list of small structs, no IO until [emit].  Optional — runtime
 * always builds one but consumers (tests, screen-overlay debug) can read
 * the events directly via [events].
 */
class RouteTrace(
    val turnId:     String,
    val transcript: String,
) {

    data class Event(
        val phase:    String,
        val outcome:  Outcome,
        val tMs:      Long,
        val detail:   String? = null,
    )

    enum class Outcome { CHECKED_SKIP, MATCHED, ERROR, DISPATCHED }

    private val startNs = System.nanoTime()
    private val _events = mutableListOf<Event>()

    val events: List<Event> get() = _events.toList()

    /** Record a phase that was checked and didn't claim the transcript. */
    fun skip(phase: String, detail: String? = null) {
        _events.add(Event(phase, Outcome.CHECKED_SKIP, elapsedMs(), detail))
    }

    /** Record a phase that claimed the transcript (early return). */
    fun matched(phase: String, detail: String? = null) {
        _events.add(Event(phase, Outcome.MATCHED, elapsedMs(), detail))
    }

    /** Record an error in a phase.  Trace continues; runtime may still recover. */
    fun error(phase: String, detail: String) {
        _events.add(Event(phase, Outcome.ERROR, elapsedMs(), detail))
    }

    /** Record that a tool was dispatched (success or failure). */
    fun dispatched(tool: String, success: Boolean) {
        _events.add(Event(
            phase   = "dispatch",
            outcome = Outcome.DISPATCHED,
            tMs     = elapsedMs(),
            detail  = "tool=$tool success=$success",
        ))
    }

    /** Format + log the full trace.  Call once when routing for this turn ends. */
    fun emit() {
        val total = elapsedMs()
        val flow = _events.joinToString(" → ") { ev ->
            val tail = when (ev.outcome) {
                Outcome.CHECKED_SKIP -> "(skip)"
                Outcome.MATCHED      -> "(match)"
                Outcome.ERROR        -> "(err:${ev.detail})"
                Outcome.DISPATCHED   -> "(${ev.detail.orEmpty()})"
            }
            "${ev.phase}$tail+${ev.tMs}ms"
        }
        Log.d(TAG, "[ROUTE_TRACE] turn=$turnId transcript=\"$transcript\" $flow total=${total}ms")
    }

    private fun elapsedMs(): Long = (System.nanoTime() - startNs) / 1_000_000L

    companion object { private const val TAG = "RouteTrace" }
}
