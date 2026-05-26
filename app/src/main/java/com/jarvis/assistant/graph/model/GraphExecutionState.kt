package com.jarvis.assistant.graph.model

/**
 * Snapshot of a graph execution — in progress or completed.
 *
 * @param graphId       The id of the graph being executed.
 * @param status        Current lifecycle status.
 * @param results       Per-node outcomes keyed by node id; populated as nodes
 *                      complete.  Ordered by insertion (LinkedHashMap semantics).
 * @param currentNodeId The node currently executing, or null when idle/done.
 * @param startedAtMs   Epoch ms when execution began.
 * @param endedAtMs     Epoch ms when execution terminated (null if ongoing).
 */
data class GraphExecutionState(
    val graphId: String,
    val status: ExecutionStatus,
    val results: Map<String, ActionResult>,
    val currentNodeId: String?,
    val startedAtMs: Long,
    val endedAtMs: Long? = null,
) {
    val isTerminal: Boolean
        get() = status in TERMINAL_STATUSES

    /** Convenience: the spoken feedback from the last node that produced one. */
    val lastFeedback: String
        get() = results.values.lastOrNull { it.spokenFeedback.isNotBlank() }
            ?.spokenFeedback ?: ""

    companion object {
        private val TERMINAL_STATUSES = setOf(
            ExecutionStatus.COMPLETED,
            ExecutionStatus.FAILED,
            ExecutionStatus.CANCELLED,
        )
    }
}

enum class ExecutionStatus {
    IDLE,
    RUNNING,
    PAUSED_FOR_CONFIRMATION,
    COMPLETED,
    FAILED,
    CANCELLED,
}
