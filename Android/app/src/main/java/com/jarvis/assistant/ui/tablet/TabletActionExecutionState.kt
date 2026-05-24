package com.jarvis.assistant.ui.tablet

import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics

// ── Step-level status ─────────────────────────────────────────────────────────

enum class ActionStepStatus {
    /** Queued but not yet started. */
    PENDING,
    /** Currently executing. */
    ACTIVE,
    /** Finished successfully. */
    COMPLETE,
    /** Execution failed. */
    FAILED,
    /** Bypassed because a prior step failed. */
    SKIPPED,
    /** Waiting for user input before proceeding. */
    WAITING_INPUT,
}

// ── Single action step ────────────────────────────────────────────────────────

/**
 * One visual step in the action planner timeline.
 *
 * Steps are derived from live [DeviceStateStore] transitions and, after
 * completion, from [ActionJournalDao] entries — so they reflect real
 * tool-execution history, not invented descriptions.
 */
data class ActionStepEntry(
    val id          : String,
    val description : String,
    val status      : ActionStepStatus,
    val toolName    : String? = null,
    /** Short extra detail shown below the description (tool result, latency, etc.). */
    val detail      : String? = null,
    val durationMs  : Long    = 0L,
    val timestampMs : Long    = 0L,
)

// ── Plan-level status ─────────────────────────────────────────────────────────

enum class ActionPlanStatus {
    /** No active or recent plan. */
    IDLE,
    /** LLM is reasoning about the utterance. */
    THINKING,
    /** One or more tools are executing. */
    EXECUTING,
    /** All steps finished. */
    COMPLETE,
    /** Execution halted due to a step failure. */
    FAILED,
    /** Multi-step plan offered; waiting for user "go / cancel". */
    WAITING_CONFIRM,
}

// ── Composite plan state ──────────────────────────────────────────────────────

/**
 * The full state of the action planner at a point in time.
 *
 * Consumed by [TabletActionPlanPanel] to render the timeline UI.
 * Produced by [TabletActionPlannerViewModel] which watches [DeviceStateStore]
 * and [LocalRouteDiagnostics] — no separate execution engine.
 */
data class TabletActionPlanState(
    val status          : ActionPlanStatus              = ActionPlanStatus.IDLE,
    val userIntent      : String                        = "",
    val steps           : List<ActionStepEntry>         = emptyList(),
    /** Last N single-step routes from the ring buffer for the history section. */
    val recentRoutes    : List<LocalRouteDiagnostics.Entry> = emptyList(),
    /** Index into [steps] of the currently running step (-1 = none). */
    val activeStepIndex : Int                           = -1,
    /** Short summary label (e.g. "Thinking…", "Running: open_app", "Done"). */
    val summary         : String                        = "",
    val lastUpdatedMs   : Long                          = 0L,
    /** Live task snapshot from [TabletActiveTaskStore] — shown in the planner header. */
    val activeTask      : TabletActiveTask?             = null,
)
