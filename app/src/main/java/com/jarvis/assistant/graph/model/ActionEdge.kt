package com.jarvis.assistant.graph.model

/**
 * A directed connection between two [ActionNode]s.
 *
 * [condition] controls when this edge is traversed:
 *  - ALWAYS         — traverse regardless of the source node's outcome.
 *  - ON_SUCCESS     — traverse when the source node succeeded.
 *  - ON_FAILURE     — traverse when the source failed or timed out.
 *  - ON_CONFIRM_YES — traverse when the user confirmed a CONFIRMATION node.
 *  - ON_CONFIRM_NO  — traverse when the user declined (or it timed out).
 *
 * Evaluation order: specific conditions (non-ALWAYS) are checked first;
 * ALWAYS edges act as the catch-all fallback.  Multiple matching edges
 * are not an error — the executor picks the first one in graph.edges order.
 */
data class ActionEdge(
    val from: String,
    val to: String,
    val condition: EdgeCondition = EdgeCondition.ON_SUCCESS,
)

enum class EdgeCondition {
    ALWAYS,
    ON_SUCCESS,
    ON_FAILURE,
    ON_CONFIRM_YES,
    ON_CONFIRM_NO,
}
