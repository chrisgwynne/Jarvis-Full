package com.jarvis.assistant.graph

import com.jarvis.assistant.graph.model.ActionGraph

/**
 * ActionPlanBuilder — maps a user transcript to a registered [ActionGraph].
 *
 * ## Matching
 *
 * Each graph declares [ActionGraph.triggerPhrases].  The builder normalises
 * the transcript to lowercase and tests whether any trigger phrase is a
 * substring of it (or vice versa).  Graphs are tested in registration order;
 * the first match wins.
 *
 * ## Param injection
 *
 * The optional [paramExtractor] callback lets callers override node params
 * at match time — useful when a trigger phrase can carry dynamic values
 * ("leave for the stadium" → destination override for the navigate node).
 * The extractor receives the normalised transcript and the matched graph; it
 * should return only the params it wants to override.
 *
 * @param graphs         Ordered list of action graphs; more specific ones first.
 * @param paramExtractor Optional per-match param override; return emptyMap() to
 *                       leave the template params unchanged.
 */
class ActionPlanBuilder(
    val graphs: List<ActionGraph>,
    private val paramExtractor: ((transcript: String, graph: ActionGraph) -> Map<String, Map<String, String>>)? = null,
) {
    /**
     * Returns the first [ActionGraph] whose trigger phrases match [transcript],
     * optionally with node-level param overrides injected from [paramExtractor].
     * Returns null if no graph matches.
     */
    fun match(transcript: String): ActionGraph? {
        val normalised = transcript.trim().lowercase()
        val graph = graphs.firstOrNull { g ->
            g.triggerPhrases.any { phrase ->
                normalised.contains(phrase.lowercase()) ||
                    phrase.lowercase().contains(normalised)
            }
        } ?: return null

        val overrides = paramExtractor?.invoke(normalised, graph) ?: return graph
        if (overrides.isEmpty()) return graph

        // Rebuild nodes with injected params
        val patchedNodes = graph.nodes.mapValues { (id, node) ->
            val extra = overrides[id] ?: return@mapValues node
            node.copy(params = node.params + extra)
        }
        return graph.copy(nodes = patchedNodes)
    }
}
