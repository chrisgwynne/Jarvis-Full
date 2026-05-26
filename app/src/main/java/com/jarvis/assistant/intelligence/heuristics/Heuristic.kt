package com.jarvis.assistant.intelligence.heuristics

import com.jarvis.assistant.core.events.Event
import com.jarvis.assistant.intelligence.model.RawSuggestion
import com.jarvis.assistant.proactive.ContextSnapshot

/**
 * Heuristic — a single deterministic rule that evaluates recent [Event]s and
 * an optional [ContextSnapshot], returning a [RawSuggestion] when the
 * condition fires or null when it does not.
 *
 * Heuristics are registered in [BehaviouralHeuristicsRegistry] and evaluated
 * on every intelligence tick.  Each must be:
 *
 *   - **Fast** — synchronous, no I/O.
 *   - **Stateless in evaluation** — may keep read-only derived state across
 *     calls but must not mutate external systems.
 *   - **Idempotent** — calling [evaluate] twice with identical inputs returns
 *     an equivalent result.
 *
 * Deduplication is handled upstream by [com.jarvis.assistant.intelligence
 * .ContextIntelligenceEngine] via [com.jarvis.assistant.proactive.CooldownStore].
 */
interface Heuristic {
    /** Stable identifier used for timeline deduplication and logging. */
    val id: String

    /**
     * Evaluate whether this heuristic fires given [recentEvents] (typically
     * the last 5–10 minutes of [EventBus] history) and [snapshot] (the most
     * recent [ContextSnapshot] from [ProactiveEngine], or null early in startup).
     *
     * Return null to indicate "no suggestion at this moment".
     */
    fun evaluate(recentEvents: List<Event>, snapshot: ContextSnapshot?): RawSuggestion?
}
