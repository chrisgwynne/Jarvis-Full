package com.jarvis.assistant.ui.tablet

import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.diagnostics.LocalRouteDiagnostics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * TabletContextBridge — process-wide singleton that bridges existing Jarvis
 * execution/routing output into the tablet workstation UI state stores.
 *
 * WHAT IT DOES:
 *  1. Observes [DeviceStateStore.state] and mirrors live pipeline transitions
 *     (Thinking → ToolRunning → Speaking → Idle) into [TabletActiveTaskStore].
 *  2. Registers as [LocalRouteDiagnostics.dispatchListener] to receive a
 *     callback after every successful local-tool dispatch — the only touch
 *     point with JarvisRuntime that requires no JarvisRuntime modification.
 *
 * WHAT IT DOES NOT DO:
 *  - Never re-dispatches tools.
 *  - Never duplicates intent routing.
 *  - Never creates a second execution pipeline.
 *  - Is purely observational + state-forwarding.
 *
 * LIFECYCLE:
 *  [attach] is called by [TabletNavHost]'s DisposableEffect when the tablet
 *  shell enters the Composition.  [detach] is called in onDispose.
 */
object TabletContextBridge {

    @Volatile
    var isTabletActive: Boolean = false
        private set

    @Volatile
    private var scope: CoroutineScope? = null

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /**
     * Start observing Jarvis state.
     * Called once per tablet shell session; safe to call again after [detach].
     */
    fun attach() {
        if (isTabletActive) return
        isTabletActive = true

        val s = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = s

        // Mirror DeviceState transitions into TabletActiveTaskStore.
        s.launch {
            DeviceStateStore.state
                .map { ds -> ds.runtimeState to ds }
                .distinctUntilChanged { a, b -> a.first == b.first }
                .collect { (state, ds) -> onDeviceStateChange(state, ds) }
        }

        // Hook into the LocalRouteDiagnostics ring buffer so we learn about
        // every tool that completes (including non-state-change silent tools).
        LocalRouteDiagnostics.dispatchListener = ::onToolDispatched
    }

    /**
     * Stop observing.  Called from the Composition's onDispose.
     * All coroutines are cancelled; [LocalRouteDiagnostics.dispatchListener]
     * is cleared so there are no leaked references.
     */
    fun detach() {
        isTabletActive = false
        scope?.cancel()
        scope = null
        LocalRouteDiagnostics.dispatchListener = null
    }

    // ── DeviceState → ActiveTask mapping ──────────────────────────────────────

    private fun onDeviceStateChange(
        state: JarvisState,
        ds   : com.jarvis.assistant.core.store.DeviceState,
    ) {
        val task: TabletActiveTask? = when (state) {
            is JarvisState.WakeDetected -> TabletActiveTask(
                description = "Wake phrase detected",
                status      = TabletTaskStatus.ACTIVE,
            )
            is JarvisState.Listening -> TabletActiveTask(
                description = "Listening…",
                status      = TabletTaskStatus.ACTIVE,
            )
            is JarvisState.Thinking -> TabletActiveTask(
                description = if (ds.lastUserUtterance.isNotBlank())
                    "Thinking: \"${ds.lastUserUtterance.take(50)}\"" else "Thinking…",
                status = TabletTaskStatus.ACTIVE,
            )
            is JarvisState.ToolRunning -> TabletActiveTask(
                description = toolDisplayName(state.toolName),
                toolName    = state.toolName,
                status      = TabletTaskStatus.ACTIVE,
            )
            is JarvisState.Speaking -> TabletActiveTask(
                description = ds.lastAssistantResponse
                    .take(70)
                    .let { if (ds.lastAssistantResponse.length > 70) "$it…" else it }
                    .ifBlank { "Delivering response…" },
                toolName    = null,
                status      = TabletTaskStatus.SUCCESS,
            )
            is JarvisState.OfflineFallback -> TabletActiveTask(
                description = "Offline — cloud LLM unreachable",
                status      = TabletTaskStatus.FAILURE,
            )
            is JarvisState.MicUnavailable -> TabletActiveTask(
                description = "Microphone unavailable",
                status      = TabletTaskStatus.WAITING,
            )
            // Idle/stopped/call states → clear the task
            is JarvisState.IdleWake,
            is JarvisState.Silenced,
            is JarvisState.ServiceStopped,
            is JarvisState.Interrupted    -> null
            else                          -> null
        }
        TabletActiveTaskStore.update(task)
    }

    // ── LocalRouteDiagnostics hook ────────────────────────────────────────────

    /**
     * Called after every successful (or failed) local-tool dispatch.
     * Updates [TabletActiveTaskStore] with a post-execution summary.
     */
    private fun onToolDispatched(entry: LocalRouteDiagnostics.Entry) {
        if (!isTabletActive) return

        val task = if (entry.result.startsWith("success")) {
            TabletActiveTask(
                description = "Done: ${intentLabel(entry.intent)}",
                toolName    = entry.tool,
                status      = TabletTaskStatus.SUCCESS,
            )
        } else if (entry.result.startsWith("failure") || entry.result.startsWith("denied")) {
            TabletActiveTask(
                description = "Failed: ${intentLabel(entry.intent)}",
                toolName    = entry.tool,
                status      = TabletTaskStatus.FAILURE,
            )
        } else {
            null
        }
        if (task != null) TabletActiveTaskStore.update(task)
    }

    // ── Label helpers ─────────────────────────────────────────────────────────

    private fun toolDisplayName(name: String): String = when (name) {
        "send_email"           -> "Composing email…"
        "open_app"             -> "Opening app…"
        "close_app"            -> "Closing app…"
        "call"                 -> "Calling…"
        "send_whatsapp"        -> "Sending WhatsApp…"
        "send_sms"             -> "Sending message…"
        "smart_home"           -> "Controlling home…"
        "navigate"             -> "Starting navigation…"
        "take_screenshot"      -> "Taking screenshot…"
        "tablet_file_context"  -> "File operation…"
        "tablet_compose"       -> "Updating email…"
        "calendar"             -> "Checking calendar…"
        "reminder"             -> "Setting reminder…"
        "timer"                -> "Setting timer…"
        "alarm"                -> "Setting alarm…"
        "web_search"           -> "Searching the web…"
        "weather"              -> "Checking weather…"
        else                   -> "${name.replace('_', ' ')
            .replaceFirstChar { it.uppercase() }}…"
    }

    private fun intentLabel(intent: String): String =
        intent.replace('_', ' ').replaceFirstChar { it.uppercase() }
}
