package com.jarvis.assistant.graph

import android.util.Log
import com.jarvis.assistant.graph.model.ActionGraph
import com.jarvis.assistant.graph.model.GraphExecutionState
import com.jarvis.assistant.graph.model.NodeStatus
import com.jarvis.assistant.graph.model.NodeType
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolRegistry

/**
 * ActionRollback — reverses successfully-completed reversible steps.
 *
 * On a graph failure the caller may invoke [rollback] to attempt to undo any
 * side effects that were already applied.  Only TOOL_CALL nodes whose
 * [Tool.isReversible] flag is true are considered; all others are skipped
 * silently.  Undo is processed in LIFO order (most recent first).
 *
 * Rollback is best-effort: individual undo failures are logged but do not
 * abort the loop.
 */
object ActionRollback {

    private const val TAG = "ActionRollback"

    /**
     * Undo every successfully-completed reversible TOOL_CALL node in [state],
     * in reverse order.
     *
     * @param state    The execution state containing per-node results.
     * @param graph    The graph whose nodes map provides tool names + params.
     * @param registry The live registry used to look up tools by name.
     */
    suspend fun rollback(
        state: GraphExecutionState,
        graph: ActionGraph,
        registry: ToolRegistry,
    ) {
        val reversibleIds = state.results
            .filter { (_, r) -> r.status == NodeStatus.SUCCESS }
            .keys
            .toList()
            .reversed()

        if (reversibleIds.isEmpty()) return
        Log.d(TAG, "Rolling back ${reversibleIds.size} node(s) in graph '${graph.id}'")

        for (nodeId in reversibleIds) {
            val node = graph.nodes[nodeId] ?: continue
            if (node.type != NodeType.TOOL_CALL) continue
            val toolName = node.toolName ?: continue
            val tool = registry.findByName(toolName) ?: continue
            if (!tool.isReversible) continue

            val result = state.results[nodeId] ?: continue
            Log.d(TAG, "Undoing node '$nodeId' via '${tool.name}'")
            try {
                tool.undo(
                    input   = ToolInput(transcript = node.label, params = node.params),
                    journal = result.rawData,
                )
            } catch (e: Exception) {
                Log.w(TAG, "Undo failed for node '$nodeId': ${e.message}")
            }
        }
    }
}
