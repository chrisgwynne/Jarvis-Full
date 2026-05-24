package com.jarvis.assistant.tools.device

import android.util.Log
import com.jarvis.assistant.graph.ActionGraphExecutor
import com.jarvis.assistant.graph.ActionPlanBuilder
import com.jarvis.assistant.graph.ActionRollback
import com.jarvis.assistant.graph.model.ExecutionStatus
import com.jarvis.assistant.graph.templates.GraphTemplates
import com.jarvis.assistant.tools.framework.Tool
import com.jarvis.assistant.tools.framework.ToolInput
import com.jarvis.assistant.tools.framework.ToolResult

/**
 * ActionGraphTool — [Tool] adapter bridging the voice pipeline to the
 * Unified Action Graph system.
 *
 * ## Role in the pipeline
 *
 * Registered in [ToolRegistry] and allowlisted in
 * [InstantCommandRouter.INSTANT_TOOL_INTENTS] under `"run_graph"`.
 * When the user's transcript matches a graph trigger phrase the
 * [InstantCommandRouter] routes it here — bypassing the LLM entirely.
 *
 * ## Circular-dependency resolution
 *
 * [ActionGraphExecutor] needs the live [ToolRegistry] to look up tools by
 * name, but the registry is being built when this tool is registered.
 * The [executorProvider] lambda resolves at execute-time (not at
 * registration time), breaking the cycle exactly as [PlanRunnerProvider]
 * does for [RunRoutineTool].
 *
 * @param executorProvider  Lazy reference to the live [ActionGraphExecutor];
 *                          returns null until the executor is initialised.
 * @param builder           [ActionPlanBuilder] pre-loaded with all templates.
 */
class ActionGraphTool(
    private val executorProvider: () -> ActionGraphExecutor?,
    private val builder: ActionPlanBuilder = ActionPlanBuilder(GraphTemplates.all),
) : Tool {

    override val name        = "run_graph"
    override val description = "Execute a multi-step action plan (routine)"

    companion object {
        private const val TAG = "ActionGraphTool"
    }

    override fun matches(transcript: String): ToolInput? {
        val graph = builder.match(transcript) ?: return null
        Log.d(TAG, "Matched graph '${graph.id}' for: \"${transcript.take(60)}\"")
        return ToolInput(transcript, mapOf("graph_id" to graph.id))
    }

    override suspend fun execute(input: ToolInput): ToolResult {
        val executor = executorProvider() ?: return ToolResult.Failure(
            "Routine executor isn't ready yet — try again in a moment."
        )

        val graphId = input.param("graph_id")
        val graph   = builder.graphs.firstOrNull { it.id == graphId }
            ?: return ToolResult.Failure("I couldn't find that routine.")

        Log.d(TAG, "Executing graph '${graph.id}'")
        val state = executor.execute(graph)

        if (state.status == ExecutionStatus.FAILED) {
            Log.w(TAG, "Graph '${graph.id}' failed — attempting rollback")
            try {
                ActionRollback.rollback(state, graph, executor.registry)
            } catch (e: Exception) {
                Log.w(TAG, "Rollback threw: ${e.message}")
            }
        }

        val feedback = when (state.status) {
            ExecutionStatus.COMPLETED -> state.lastFeedback.ifBlank { "Done." }
            ExecutionStatus.CANCELLED -> "Cancelled."
            ExecutionStatus.FAILED    -> "Something went wrong with ${graph.displayName}."
            else                      -> ""
        }

        return if (state.status == ExecutionStatus.COMPLETED || state.status == ExecutionStatus.CANCELLED) {
            ToolResult.Success(spokenFeedback = feedback, silent = feedback.isBlank())
        } else {
            ToolResult.Failure(spokenFeedback = feedback)
        }
    }
}
