package com.jarvis.assistant.graph

import android.util.Log
import com.jarvis.assistant.graph.model.ActionGraph
import com.jarvis.assistant.graph.model.ActionNode
import com.jarvis.assistant.graph.model.ActionResult
import com.jarvis.assistant.graph.model.EdgeCondition
import com.jarvis.assistant.graph.model.ExecutionStatus
import com.jarvis.assistant.graph.model.GraphExecutionState
import com.jarvis.assistant.graph.model.NodeStatus
import com.jarvis.assistant.graph.model.NodeType
import com.jarvis.assistant.overlay.OverlayEventBridge
import com.jarvis.assistant.overlay.model.OverlayAction
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import com.jarvis.assistant.overlay.model.OverlayPriority
import com.jarvis.assistant.remote.brain.MacRemoteCommandExecutor
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolRegistry
import com.jarvis.assistant.tools.framework.ToolResult
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/**
 * ActionGraphExecutor — walks an [ActionGraph] node by node, executing each
 * step and following edges based on outcomes.
 *
 * ## Execution model
 *
 *  1. Optionally show a pre-start confirmation overlay.
 *  2. Walk from [ActionGraph.startNodeId] following [ActionEdge]s.
 *  3. For each node, show a progress overlay then dispatch:
 *     - TOOL_CALL   → [ToolRegistry.findByName] + [Tool.execute]
 *     - MAC_BRIDGE  → [MacBridgeCommandExecutor.execute]
 *     - CONFIRMATION → overlay with Yes/No; suspend until resolved or timed out
 *     - DELAY       → [kotlinx.coroutines.delay] for params["delayMs"]
 *     - CONDITION   → evaluate a prior node's result; route accordingly
 *  4. Return a final [GraphExecutionState] with per-node results.
 *
 * ## Thread safety
 *
 * All suspension happens inside coroutines.  [execute] is a suspend function
 * and must be called from a coroutine scope.  No shared mutable state is
 * exposed outside the function.
 *
 * @param registry      The live tool registry; provides [ToolRegistry.findByName].
 * @param bridgeExecutor  Optional Mac remote command executor for MAC_BRIDGE nodes.
 * @param bridgeConfig  Unused legacy parameter — kept for source compatibility.
 */
class ActionGraphExecutor(
    val registry: ToolRegistry,
    private val bridgeExecutor: MacRemoteCommandExecutor? = null,
    private val bridgeConfig: Any? = null,
) {

    companion object {
        private const val TAG = "ActionGraphExecutor"
        private const val DEFAULT_TIMEOUT_MS   = 15_000L
        private const val CONFIRMATION_TIMEOUT = 30_000L
    }

    // ── Public entry point ────────────────────────────────────────────────────

    suspend fun execute(graph: ActionGraph): GraphExecutionState {
        Log.d(TAG, "Starting graph '${graph.id}'")
        val results   = linkedMapOf<String, ActionResult>()
        val startedAt = System.currentTimeMillis()

        if (graph.confirmBeforeStart) {
            val confirmed = requestConfirmation(
                title     = "Run \"${graph.displayName}\"?",
                message   = graph.description,
                dedupeKey = "graph_pre_${graph.id}",
            )
            if (!confirmed) {
                Log.d(TAG, "Graph '${graph.id}' cancelled before start")
                return finalState(graph.id, ExecutionStatus.CANCELLED, results, startedAt)
            }
        }

        var currentId: String? = graph.startNodeId

        while (currentId != null) {
            val node = graph.nodes[currentId]
            if (node == null) {
                Log.w(TAG, "Node '$currentId' not found in graph '${graph.id}' — stopping")
                break
            }

            showProgress(node)
            val result = executeNode(node, results)
            results[node.id] = result

            Log.d(TAG, "Node '${node.id}' → ${result.status} (${result.durationMs}ms)")

            // Abort on non-optional failure
            if (result.status == NodeStatus.FAILURE && !node.optional) {
                return finalState(graph.id, ExecutionStatus.FAILED, results, startedAt)
            }

            currentId = resolveNext(graph, node, result)
        }

        return finalState(graph.id, ExecutionStatus.COMPLETED, results, startedAt)
    }

    // ── Node dispatch ─────────────────────────────────────────────────────────

    private suspend fun executeNode(
        node: ActionNode,
        priorResults: Map<String, ActionResult>,
    ): ActionResult = when (node.type) {
        NodeType.TOOL_CALL    -> executeToolCall(node)
        NodeType.MAC_BRIDGE   -> executeMacBridge(node)
        NodeType.CONFIRMATION -> executeConfirmation(node)
        NodeType.DELAY        -> executeDelay(node)
        NodeType.CONDITION    -> evaluateCondition(node, priorResults)
    }

    // ── TOOL_CALL ─────────────────────────────────────────────────────────────

    private suspend fun executeToolCall(node: ActionNode): ActionResult {
        val t0 = now()
        val toolName = node.toolName ?: return ActionResult(
            nodeId = node.id,
            status = NodeStatus.FAILURE,
            spokenFeedback = "Step '${node.label}' has no tool name.",
            durationMs = elapsed(t0),
        )
        val tool = registry.findByName(toolName) ?: return ActionResult(
            nodeId = node.id,
            status = if (node.optional) NodeStatus.SKIPPED else NodeStatus.FAILURE,
            spokenFeedback = "Step '${node.label}' ($toolName) is unavailable right now.",
            durationMs = elapsed(t0),
        )

        val timeout = if (node.timeoutMs > 0) node.timeoutMs else DEFAULT_TIMEOUT_MS
        return try {
            val toolResult = kotlinx.coroutines.withTimeout(timeout) {
                tool.execute(ToolInput(transcript = node.label, params = node.params))
            }
            when (toolResult) {
                is ToolResult.Success -> ActionResult(
                    nodeId = node.id,
                    status = NodeStatus.SUCCESS,
                    spokenFeedback = toolResult.spokenFeedback,
                    rawData = toolResult.rawData,
                    durationMs = elapsed(t0),
                )
                is ToolResult.Failure -> ActionResult(
                    nodeId = node.id,
                    status = if (node.optional) NodeStatus.SKIPPED else NodeStatus.FAILURE,
                    spokenFeedback = toolResult.spokenFeedback,
                    durationMs = elapsed(t0),
                )
                else -> ActionResult(
                    nodeId = node.id,
                    status = if (node.optional) NodeStatus.SKIPPED else NodeStatus.FAILURE,
                    durationMs = elapsed(t0),
                )
            }
        } catch (_: TimeoutCancellationException) {
            ActionResult(
                nodeId = node.id,
                status = NodeStatus.TIMED_OUT,
                spokenFeedback = "Step '${node.label}' timed out.",
                durationMs = elapsed(t0),
            )
        }
    }

    // ── MAC_BRIDGE ────────────────────────────────────────────────────────────

    private suspend fun executeMacBridge(node: ActionNode): ActionResult {
        val t0  = now()
        val exec = bridgeExecutor ?: return ActionResult(
            nodeId = node.id,
            status = if (node.optional) NodeStatus.SKIPPED else NodeStatus.FAILURE,
            spokenFeedback = "Mac Bridge is not available.",
            durationMs = elapsed(t0),
        )
        val command = node.toolName ?: return ActionResult(
            nodeId = node.id,
            status = NodeStatus.FAILURE,
            spokenFeedback = "Step '${node.label}' has no bridge command.",
            durationMs = elapsed(t0),
        )
        val payload = JSONObject().also { jo -> node.params.forEach { (k, v) -> jo.put(k, v) } }
        val result = exec.execute(command, payload)
        return ActionResult(
            nodeId = node.id,
            status = if (result.ok) NodeStatus.SUCCESS
                     else if (node.optional) NodeStatus.SKIPPED
                     else NodeStatus.FAILURE,
            spokenFeedback = result.message ?: "",
            durationMs = elapsed(t0),
        )
    }

    // ── CONFIRMATION ──────────────────────────────────────────────────────────

    private suspend fun executeConfirmation(node: ActionNode): ActionResult {
        val t0      = now()
        val title   = node.overlayTitle ?: node.label
        val message = node.params["message"] ?: "Proceed with ${node.label}?"
        val confirmed = requestConfirmation(title, message, "graph_conf_${node.id}")
        return ActionResult(
            nodeId = node.id,
            status = if (confirmed) NodeStatus.SUCCESS else NodeStatus.CANCELLED,
            durationMs = elapsed(t0),
        )
    }

    // ── DELAY ─────────────────────────────────────────────────────────────────

    private suspend fun executeDelay(node: ActionNode): ActionResult {
        val t0      = now()
        val delayMs = node.params["delayMs"]?.toLongOrNull() ?: 1_000L
        delay(delayMs)
        return ActionResult(nodeId = node.id, status = NodeStatus.SUCCESS, durationMs = elapsed(t0))
    }

    // ── CONDITION ─────────────────────────────────────────────────────────────

    private fun evaluateCondition(
        node: ActionNode,
        priorResults: Map<String, ActionResult>,
    ): ActionResult {
        val t0  = now()
        val key = node.condition ?: return ActionResult(
            nodeId = node.id,
            status = NodeStatus.FAILURE,
            spokenFeedback = "Condition '${node.label}' has no target node id.",
            durationMs = elapsed(t0),
        )
        val passed = priorResults[key]?.status == NodeStatus.SUCCESS
        return ActionResult(
            nodeId = node.id,
            status = if (passed) NodeStatus.SUCCESS else NodeStatus.FAILURE,
            durationMs = elapsed(t0),
        )
    }

    // ── Edge resolution ───────────────────────────────────────────────────────

    private fun resolveNext(
        graph: ActionGraph,
        node: ActionNode,
        result: ActionResult,
    ): String? {
        val isConfirmNode = node.type == NodeType.CONFIRMATION
        val succeeded     = result.status == NodeStatus.SUCCESS
        val edges         = graph.edges.filter { it.from == node.id }

        val specific = edges.firstOrNull { edge ->
            when (edge.condition) {
                EdgeCondition.ALWAYS         -> false
                EdgeCondition.ON_SUCCESS     -> succeeded && !isConfirmNode
                EdgeCondition.ON_FAILURE     -> !succeeded && !isConfirmNode
                EdgeCondition.ON_CONFIRM_YES -> isConfirmNode && succeeded
                EdgeCondition.ON_CONFIRM_NO  -> isConfirmNode && !succeeded
            }
        }
        return (specific ?: edges.firstOrNull { it.condition == EdgeCondition.ALWAYS })?.to
    }

    // ── Overlay helpers ───────────────────────────────────────────────────────

    private fun showProgress(node: ActionNode) {
        val title = node.overlayTitle ?: node.label
        if (title.isBlank()) return
        OverlayEventBridge.show(
            OverlayCard(
                type     = OverlayCardType.PROACTIVE_PROMPT,
                title    = title,
                message  = "",
                dedupKey = "graph_progress_${node.id}",
                priority = OverlayPriority.NORMAL,
                actions  = emptyList(),
            )
        )
    }

    private suspend fun requestConfirmation(
        title: String,
        message: String,
        dedupeKey: String,
    ): Boolean {
        val deferred = CompletableDeferred<Boolean>()
        val yesKey   = "${dedupeKey}_yes"
        val noKey    = "${dedupeKey}_no"

        OverlayEventBridge.onAction(yesKey) {
            OverlayEventBridge.clearAction(yesKey)
            OverlayEventBridge.clearAction(noKey)
            deferred.complete(true)
        }
        OverlayEventBridge.onAction(noKey) {
            OverlayEventBridge.clearAction(yesKey)
            OverlayEventBridge.clearAction(noKey)
            deferred.complete(false)
        }

        OverlayEventBridge.show(
            OverlayCard(
                type     = OverlayCardType.PROACTIVE_PROMPT,
                title    = title,
                message  = message,
                dedupKey = dedupeKey,
                priority = OverlayPriority.HIGH,
                actions  = listOf(
                    OverlayAction(actionKey = yesKey, label = "Yes", isPrimary = true),
                    OverlayAction(actionKey = noKey,  label = "No",  isPrimary = false),
                ),
            )
        )

        return try {
            withTimeoutOrNull(CONFIRMATION_TIMEOUT) { deferred.await() } ?: false
        } finally {
            OverlayEventBridge.clearAction(yesKey)
            OverlayEventBridge.clearAction(noKey)
        }
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    private fun now()          = System.currentTimeMillis()
    private fun elapsed(t0: Long) = now() - t0

    private fun finalState(
        graphId: String,
        status: ExecutionStatus,
        results: Map<String, ActionResult>,
        startedAt: Long,
    ) = GraphExecutionState(
        graphId       = graphId,
        status        = status,
        results       = results,
        currentNodeId = null,
        startedAtMs   = startedAt,
        endedAtMs     = now(),
    )
}
