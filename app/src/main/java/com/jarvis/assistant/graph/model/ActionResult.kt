package com.jarvis.assistant.graph.model

/**
 * The outcome of executing a single [ActionNode].
 *
 * @param nodeId        The id of the node this result belongs to.
 * @param status        How the node resolved.
 * @param spokenFeedback  Optional text to speak or show; from ToolResult.
 * @param rawData       Raw payload from a successful ToolResult — used by
 *                      [ActionRollback] as the journal for undo.
 * @param durationMs    Wall-clock time the node took to execute.
 */
data class ActionResult(
    val nodeId: String,
    val status: NodeStatus,
    val spokenFeedback: String = "",
    val rawData: String = "",
    val durationMs: Long = 0,
)

enum class NodeStatus {
    SUCCESS,
    FAILURE,
    SKIPPED,
    TIMED_OUT,
    CANCELLED,
}
