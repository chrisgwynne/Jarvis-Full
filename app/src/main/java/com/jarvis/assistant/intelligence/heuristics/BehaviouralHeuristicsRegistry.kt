package com.jarvis.assistant.intelligence.heuristics

/**
 * BehaviouralHeuristicsRegistry — the ordered list of [Heuristic]s evaluated
 * on every intelligence tick.
 *
 * ## Adding a new heuristic
 *
 *   1. Implement [Heuristic] (in [BuiltInHeuristics] or a new file).
 *   2. Append an instance to [heuristics] here.
 *   3. Done — no changes elsewhere required.
 *
 * Evaluation order matters only for logging; scoring happens downstream in
 * [com.jarvis.assistant.intelligence.SuggestionScorer] so earlier entries
 * do not shadow later ones.
 */
class BehaviouralHeuristicsRegistry(
    val heuristics: List<Heuristic> = BuiltInHeuristics.all,
)
