package com.jarvis.assistant.graph.model

/**
 * A single step within an [ActionGraph].
 *
 * @param id           Unique node id within its graph.
 * @param type         What kind of step this is.
 * @param label        Human-readable label for progress overlays and logs.
 * @param toolName     For TOOL_CALL: the [Tool.name].
 *                     For MAC_BRIDGE: the bridge command string.
 * @param params       Fixed key-value params forwarded to the tool / bridge
 *                     as [ToolInput.params] or a JSONObject payload.
 * @param optional     When true, a FAILURE or TIMED_OUT here follows
 *                     ON_FAILURE edges if any exist, but does NOT abort the
 *                     graph if no failure edge is wired.
 * @param timeoutMs    Per-node hard timeout in milliseconds.  0 = use the
 *                     executor's default (15 s for tool calls).
 * @param overlayTitle Short string shown in the progress overlay while this
 *                     node executes.  Falls back to [label] when null.
 * @param condition    For CONDITION nodes: the id of a prior [ActionResult]
 *                     whose [NodeStatus] is tested.  ON_SUCCESS edges fire
 *                     when that result was SUCCESS; ON_FAILURE otherwise.
 */
data class ActionNode(
    val id: String,
    val type: NodeType,
    val label: String,
    val toolName: String? = null,
    val params: Map<String, String> = emptyMap(),
    val optional: Boolean = false,
    val timeoutMs: Long = 0,
    val overlayTitle: String? = null,
    val condition: String? = null,
)

enum class NodeType {
    /** Execute a registered Tool by name. Params become ToolInput.params. */
    TOOL_CALL,
    /** Evaluate an earlier result by node id; follow SUCCESS or FAILURE edges. */
    CONDITION,
    /** Pause execution and ask the user to confirm before proceeding. */
    CONFIRMATION,
    /** Execute a MacBridge command on the paired Mac. */
    MAC_BRIDGE,
    /** Wait for params["delayMs"] milliseconds then succeed. */
    DELAY,
}
