package com.jarvis.assistant.ui.tablet

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

// ── Task status ───────────────────────────────────────────────────────────────

enum class TabletTaskStatus {
    IDLE,
    ACTIVE,
    WAITING,
    SUCCESS,
    FAILURE,
}

// ── Active task snapshot ──────────────────────────────────────────────────────

/**
 * A point-in-time description of what Jarvis is currently executing on the
 * tablet workstation.
 *
 * @param description Short human-readable label (e.g. "Composing email…", "Done").
 * @param toolName    The tool being executed, or null if in LLM-thinking phase.
 * @param status      Current lifecycle status.
 * @param startedAtMs When this task snapshot was created.
 */
data class TabletActiveTask(
    val description : String,
    val toolName    : String?          = null,
    val status      : TabletTaskStatus = TabletTaskStatus.ACTIVE,
    val startedAtMs : Long             = System.currentTimeMillis(),
)

// ── Process-wide store ────────────────────────────────────────────────────────

/**
 * TabletActiveTaskStore — process-wide StateFlow of the currently executing
 * Jarvis task, updated by [TabletContextBridge] as [DeviceStateStore] transitions.
 *
 * Consumed by:
 *  - [TabletActionPlannerViewModel] — surfaces in the planner header.
 *  - Any tablet panel that wants a live "what is Jarvis doing?" badge.
 */
object TabletActiveTaskStore {

    private val _task = MutableStateFlow<TabletActiveTask?>(null)

    /** Currently executing task, or null when idle. */
    val task: StateFlow<TabletActiveTask?> = _task.asStateFlow()

    /** Update the current task (call from [TabletContextBridge] only). */
    fun update(task: TabletActiveTask?) {
        _task.value = task
    }
}
