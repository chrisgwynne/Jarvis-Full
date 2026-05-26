package com.jarvis.assistant.ui.tablet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.store.DeviceState
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics
import com.jarvis.assistant.memory.db.JarvisDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * TabletActionPlannerViewModel — builds a visual action plan from existing
 * Jarvis execution infrastructure.
 *
 * Data sources (all read-only — no new execution engine):
 *  1. [DeviceStateStore.state] — live pipeline state (THINKING / TOOL_RUNNING /
 *     SPEAKING / IDLE etc.) drives the "current" plan timeline.
 *  2. [LocalRouteDiagnostics.stateFlow] — ring buffer of the last 30 completed
 *     single-step routes, shown in the "Recent" section.
 *  3. [ActionJournalDao] — most recent multi-step plan steps fetched on demand
 *     via [loadMostRecentPlan].
 *
 * The planner never dispatches tool calls — it only observes and visualises.
 */
class TabletActionPlannerViewModel(app: Application) : AndroidViewModel(app) {

    private val journalDao = JarvisDatabase.getInstance(app).actionJournalDao()

    private val _planState = MutableStateFlow(TabletActionPlanState())
    val planState: StateFlow<TabletActionPlanState> = _planState.asStateFlow()

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    init {
        // Track live pipeline transitions.
        viewModelScope.launch {
            DeviceStateStore.state
                .collect { ds -> updateFromDeviceState(ds) }
        }
        // Mirror recent route history.
        viewModelScope.launch {
            LocalRouteDiagnostics.stateFlow
                .collect { routes ->
                    _planState.update { it.copy(recentRoutes = routes) }
                }
        }
        // Mirror the active task store so the planner header always reflects
        // the current Jarvis execution state (set by TabletContextBridge).
        viewModelScope.launch {
            TabletActiveTaskStore.task
                .collect { task ->
                    _planState.update { it.copy(activeTask = task) }
                }
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Load the most recent multi-step plan from the Room journal and update
     * [planState] steps.  Call this when the panel becomes visible so the UI
     * always shows the last known plan even after a cold start.
     */
    fun loadMostRecentPlan() {
        viewModelScope.launch(Dispatchers.IO) {
            val planId  = journalDao.mostRecentSucceededPlanId() ?: return@launch
            val entries = journalDao.forPlan(planId)
            if (entries.isEmpty()) return@launch

            val steps = entries.map { e ->
                ActionStepEntry(
                    id          = e.id.toString(),
                    description = e.toolName.replace('_', ' ').replaceFirstChar { it.uppercase() },
                    status      = when (e.status) {
                        "SUCCEEDED" -> ActionStepStatus.COMPLETE
                        "FAILED"    -> ActionStepStatus.FAILED
                        "SKIPPED"   -> ActionStepStatus.SKIPPED
                        "UNDONE"    -> ActionStepStatus.COMPLETE  // show as complete with note
                        else        -> ActionStepStatus.PENDING
                    },
                    toolName    = e.toolName,
                    detail      = when (e.status) {
                        "FAILED"  -> "Failed"
                        "SKIPPED" -> "Skipped"
                        "UNDONE"  -> "Undone"
                        else      -> null
                    },
                    durationMs  = if (e.completedAtMs != null)
                                      e.completedAtMs - e.createdAtMs
                                  else 0L,
                    timestampMs = e.createdAtMs,
                )
            }

            _planState.update { prev ->
                prev.copy(
                    userIntent = entries.firstOrNull()?.originatingTranscript ?: prev.userIntent,
                    steps      = steps,
                    status     = ActionPlanStatus.COMPLETE,
                    summary    = "Last plan: ${steps.size} step${if (steps.size == 1) "" else "s"}",
                )
            }
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    private fun updateFromDeviceState(ds: DeviceState) {
        val now = System.currentTimeMillis()
        when (val state = ds.runtimeState) {

            is JarvisState.WakeDetected -> {
                // Wake just confirmed — start a fresh plan frame
                _planState.update { prev ->
                    prev.copy(
                        status        = ActionPlanStatus.THINKING,
                        userIntent    = "",
                        steps         = listOf(
                            ActionStepEntry(UUID.randomUUID().toString(), "Wake phrase detected", ActionStepStatus.COMPLETE),
                            ActionStepEntry(UUID.randomUUID().toString(), "Listening…",           ActionStepStatus.ACTIVE),
                        ),
                        summary       = "Listening…",
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.Listening -> {
                _planState.update { prev ->
                    val base = prev.steps.filter { it.status == ActionStepStatus.COMPLETE }
                    prev.copy(
                        status        = ActionPlanStatus.THINKING,
                        summary       = "Listening for command…",
                        steps         = base + ActionStepEntry(
                            UUID.randomUUID().toString(), "Listening…", ActionStepStatus.ACTIVE
                        ),
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.Thinking -> {
                val intent = ds.lastUserUtterance.ifBlank { "…" }
                _planState.update { prev ->
                    prev.copy(
                        status        = ActionPlanStatus.THINKING,
                        userIntent    = ds.lastUserUtterance,
                        steps         = listOf(
                            ActionStepEntry(
                                UUID.randomUUID().toString(),
                                "Heard: \"${intent.take(60)}\"",
                                ActionStepStatus.COMPLETE,
                            ),
                            ActionStepEntry(
                                UUID.randomUUID().toString(),
                                "Analysing intent…",
                                ActionStepStatus.ACTIVE,
                            ),
                        ),
                        summary       = "Thinking…",
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.ToolRunning -> {
                val intent   = ds.lastUserUtterance.ifBlank { "…" }
                val toolDisp = state.toolName.replace('_', ' ').replaceFirstChar { it.uppercase() }
                _planState.update { prev ->
                    // Preserve any already-complete steps; replace the ACTIVE one.
                    val done = prev.steps.filter { it.status == ActionStepStatus.COMPLETE }
                    prev.copy(
                        status        = ActionPlanStatus.EXECUTING,
                        userIntent    = ds.lastUserUtterance,
                        steps         = done + listOf(
                            ActionStepEntry(
                                "intent_matched",
                                "Intent matched",
                                ActionStepStatus.COMPLETE,
                            ),
                            ActionStepEntry(
                                "tool_${state.toolName}",
                                toolDisp,
                                ActionStepStatus.ACTIVE,
                                toolName = state.toolName,
                                detail   = "running…",
                            ),
                        ),
                        summary       = "Running: $toolDisp",
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.Speaking -> {
                val resp = ds.lastAssistantResponse
                    .take(80)
                    .let { if (ds.lastAssistantResponse.length > 80) "$it…" else it }
                _planState.update { prev ->
                    val done = prev.steps
                        .map { it.copy(status = ActionStepStatus.COMPLETE) }
                        .distinctBy { it.id }
                    prev.copy(
                        status        = ActionPlanStatus.COMPLETE,
                        steps         = done + ActionStepEntry(
                            "response",
                            resp.ifBlank { "Delivered response" },
                            ActionStepStatus.COMPLETE,
                        ),
                        summary       = "Done",
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.OfflineFallback -> {
                _planState.update { prev ->
                    prev.copy(
                        status        = ActionPlanStatus.FAILED,
                        summary       = "Offline — cloud LLM unreachable",
                        lastUpdatedMs = now,
                    )
                }
            }

            is JarvisState.ServiceStopped,
            is JarvisState.Silenced,
            is JarvisState.IdleWake -> {
                // Only reset if we're not mid-display of a completed plan
                if (_planState.value.status != ActionPlanStatus.COMPLETE) {
                    _planState.update { prev ->
                        prev.copy(
                            status        = ActionPlanStatus.IDLE,
                            summary       = "",
                            lastUpdatedMs = now,
                        )
                    }
                }
            }

            else -> { /* other states (call, interrupted, etc.) — no plan update */ }
        }
    }
}
