package com.jarvis.assistant.graph.model

/**
 * A directed graph describing a multi-step action plan.
 *
 * Graphs are matched from voice transcripts by [ActionPlanBuilder] and
 * executed by [ActionGraphExecutor].  They are deterministic — no LLM is
 * required for well-defined routines.
 *
 * @param id                  Stable identifier used in logs and dedup keys.
 * @param displayName         Shown in progress overlays.
 * @param description         One-line summary of what the graph does.  Used
 *                            in the pre-start confirmation overlay.
 * @param triggerPhrases      Phrases matched by [ActionPlanBuilder].  Case-
 *                            insensitive substring match against the normalised
 *                            transcript.  Register more specific graphs before
 *                            broader ones.
 * @param nodes               Map of node id → [ActionNode].
 * @param edges               Directed connections between nodes.
 * @param startNodeId         ID of the first node to execute.
 * @param confirmBeforeStart  When true, the executor asks for confirmation
 *                            before beginning.  Use for multi-step plans that
 *                            have side effects.
 */
data class ActionGraph(
    val id: String,
    val displayName: String,
    val description: String,
    val triggerPhrases: List<String>,
    val nodes: Map<String, ActionNode>,
    val edges: List<ActionEdge>,
    val startNodeId: String,
    val confirmBeforeStart: Boolean = false,
)
