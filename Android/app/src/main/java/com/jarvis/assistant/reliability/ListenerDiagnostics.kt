package com.jarvis.assistant.reliability

import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

/**
 * ListenerDiagnostics — process-wide diagnostic counters and last-event strings for
 * the Jarvis listening lifecycle.
 *
 * Designed as a push-only side-channel: each component writes its state here as a
 * side-effect of its normal work.  Consumers (the debug overlay card, logcat, tests)
 * call [snapshot] to get a coherent read at any point in time.
 *
 * ## Counters (AtomicInteger, 0 or 1 in normal operation)
 *   - [activeWakeDetectorCount]       — wake-word detector running (IdleWake phase)
 *   - [activeSpeechRecognizerCount]   — command-capture mic open (Listening phase)
 *   - [activeOverlayViewCount]        — ComposeView attached to WindowManager
 *   - [activeHaSubscriptionCount]     — HA event subscription coroutines alive
 *   - [activeMacBridgeConnectionCount]— Mac→Android bridge connection active
 *   - [notificationListenerBufferSize]— entries in JarvisNotificationListener ring buffer
 *
 * ## Last-event strings (@Volatile, latest write wins)
 *   - [lastListenStopReason]    — reason tag from the most recent [recordListenStop] call
 *   - [lastListenStopTimeMs]    — wall-clock ms of that event
 *   - [lastAudioFocusEvent]     — description of the last AudioManager focus change
 *   - [lastOverlayAttempt]      — description of the last card that tried to show
 *   - [lastOverlayBlockReason]  — why that card was suppressed (null = was allowed)
 *   - [currentListeningState]   — JarvisState simple name from the most recent syncState call
 *   - [currentRole]             — effective role string (FULL_ASSISTANT / BRIDGE_ONLY / …)
 *   - [watchdogRestartCount]    — number of watchdog-triggered restarts since process start
 *   - [lastWatchdogRestartMs]   — wall-clock ms of the last watchdog restart
 *
 * ## Thread safety
 *   AtomicInteger operations are lock-free.  @Volatile fields use single-write
 *   semantics — no CAS needed because only one component writes each field.
 */
object ListenerDiagnostics {

    private const val TAG = "ListenerDiag"

    // ── Active counters ───────────────────────────────────────────────────────

    /** Non-zero while the wake-word detector loop is running. */
    val activeWakeDetectorCount     = AtomicInteger(0)

    /** Non-zero while the command-capture microphone is open (Listening state). */
    val activeSpeechRecognizerCount = AtomicInteger(0)

    /** Non-zero while an overlay ComposeView is attached to WindowManager. */
    val activeOverlayViewCount      = AtomicInteger(0)

    /** Non-zero while a HA event subscription coroutine is alive. */
    val activeHaSubscriptionCount   = AtomicInteger(0)

    /** Non-zero while the Mac Bridge WebSocket connection is open. */
    val activeMacBridgeConnectionCount = AtomicInteger(0)

    /** Current JarvisNotificationListener ring-buffer entry count. */
    val notificationListenerBufferSize = AtomicInteger(0)

    // ── Last-event strings ────────────────────────────────────────────────────

    @Volatile var lastListenStopReason:  String? = null; private set
    @Volatile var lastListenStopTimeMs:  Long    = 0L;  private set

    @Volatile var lastThinkingStartMs:   Long    = 0L
    @Volatile var lastListeningStartMs:  Long    = 0L

    @Volatile var lastAudioFocusEvent:   String? = null
    @Volatile var lastOverlayAttempt:    String? = null
    @Volatile var lastOverlayBlockReason: String? = null

    /** Simple name of the current JarvisState, e.g. "IdleWake", "Listening". */
    @Volatile var currentListeningState: String = "UNKNOWN"

    /** Effective role string, e.g. "FULL_ASSISTANT" or "BRIDGE_ONLY". */
    @Volatile var currentRole: String = "UNKNOWN"

    // ── Remote reply tracking ─────────────────────────────────────────────────

    /** Route ID of the currently pending remote (Mac brain) reply, or null if not waiting. */
    @Volatile var pendingRemoteRouteId: String? = null

    /** Wall-clock ms when AwaitingRemoteReply was entered; 0 if not waiting. */
    @Volatile var awaitingRemoteReplySinceMs: Long = 0L

    /** Number of remote reply attempts that timed out (8-second guard). */
    val remoteReplyTimeouts = AtomicInteger(0)

    /** Number of reply.final frames dropped because no route was pending. */
    val staleReplyDrops = AtomicInteger(0)

    /** Number of reply.final frames dropped because correlationId did not match pending route. */
    val mismatchedReplyDrops = AtomicInteger(0)

    // ── Watchdog tracking ─────────────────────────────────────────────────────

    /** Number of watchdog-triggered wake-detector restarts since process start. */
    val watchdogRestartCount = AtomicInteger(0)

    @Volatile var lastWatchdogRestartMs: Long = 0L

    // ── Write API ─────────────────────────────────────────────────────────────

    /**
     * Record a listening-stop event.  Every path that stops the wake detector
     * or terminates a listen session must call this with a meaningful [reason].
     *
     * Common reasons:
     *   `audio_duck_in_idle_wake` · `audio_focus_lost` · `bridge_mode_demotion`
     *   `sample_playback_suppress` · `service_shutdown` · `unspecified`
     */
    fun recordListenStop(reason: String) {
        lastListenStopReason = reason
        lastListenStopTimeMs = System.currentTimeMillis()
        Log.w(TAG, "[listen_stop] reason=$reason")
    }

    // ── Snapshot ──────────────────────────────────────────────────────────────

    /**
     * Return a point-in-time immutable snapshot of all diagnostic state.
     * Safe to call from any thread.
     */
    fun snapshot(): DiagnosticsSnapshot = DiagnosticsSnapshot(
        activeWakeDetectorCount      = activeWakeDetectorCount.get(),
        activeSpeechRecognizerCount  = activeSpeechRecognizerCount.get(),
        activeOverlayViewCount       = activeOverlayViewCount.get(),
        activeHaSubscriptionCount    = activeHaSubscriptionCount.get(),
        activeMacBridgeConnectionCount = activeMacBridgeConnectionCount.get(),
        notificationListenerBufferSize = notificationListenerBufferSize.get(),
        lastListenStopReason         = lastListenStopReason,
        lastListenStopTimeMs         = lastListenStopTimeMs,
        lastAudioFocusEvent          = lastAudioFocusEvent,
        lastOverlayAttempt           = lastOverlayAttempt,
        lastOverlayBlockReason       = lastOverlayBlockReason,
        currentListeningState        = currentListeningState,
        currentRole                  = currentRole,
        watchdogRestartCount         = watchdogRestartCount.get(),
        lastWatchdogRestartMs        = lastWatchdogRestartMs,
        pendingRemoteRouteId         = pendingRemoteRouteId,
        awaitingRemoteReplySinceMs   = awaitingRemoteReplySinceMs,
        remoteReplyTimeouts          = remoteReplyTimeouts.get(),
        staleReplyDrops              = staleReplyDrops.get(),
        mismatchedReplyDrops         = mismatchedReplyDrops.get(),
    )

    // ── Test helpers ──────────────────────────────────────────────────────────

    /** Reset all state.  Tests only — never call in production code. */
    fun resetForTest() {
        activeWakeDetectorCount.set(0)
        activeSpeechRecognizerCount.set(0)
        activeOverlayViewCount.set(0)
        activeHaSubscriptionCount.set(0)
        activeMacBridgeConnectionCount.set(0)
        notificationListenerBufferSize.set(0)
        lastListenStopReason  = null
        lastListenStopTimeMs  = 0L
        lastAudioFocusEvent   = null
        lastOverlayAttempt    = null
        lastOverlayBlockReason = null
        currentListeningState = "UNKNOWN"
        currentRole           = "UNKNOWN"
        watchdogRestartCount.set(0)
        lastWatchdogRestartMs = 0L
        pendingRemoteRouteId = null
        awaitingRemoteReplySinceMs = 0L
        remoteReplyTimeouts.set(0)
        staleReplyDrops.set(0)
        mismatchedReplyDrops.set(0)
    }
}

// ── Snapshot ──────────────────────────────────────────────────────────────────

/**
 * Immutable point-in-time view of [ListenerDiagnostics].
 * Formatted as a compact multi-line string by [toDebugCard].
 */
data class DiagnosticsSnapshot(
    val activeWakeDetectorCount:       Int,
    val activeSpeechRecognizerCount:   Int,
    val activeOverlayViewCount:        Int,
    val activeHaSubscriptionCount:     Int,
    val activeMacBridgeConnectionCount: Int,
    val notificationListenerBufferSize: Int,
    val lastListenStopReason:          String?,
    val lastListenStopTimeMs:          Long,
    val lastAudioFocusEvent:           String?,
    val lastOverlayAttempt:            String?,
    val lastOverlayBlockReason:        String?,
    val currentListeningState:         String,
    val currentRole:                   String,
    val watchdogRestartCount:          Int,
    val lastWatchdogRestartMs:         Long,
    val pendingRemoteRouteId:          String?,
    val awaitingRemoteReplySinceMs:    Long,
    val remoteReplyTimeouts:           Int,
    val staleReplyDrops:               Int,
    val mismatchedReplyDrops:          Int,
) {
    /**
     * Compact multi-line summary suitable for the debug overlay card message field.
     * Fits in ~10 lines so it's readable on a phone screen without scrolling.
     */
    fun toDebugCard(): String = buildString {
        appendLine("Role: $currentRole  State: $currentListeningState")
        appendLine("Wake: $activeWakeDetectorCount  Recog: $activeSpeechRecognizerCount  Overlay: $activeOverlayViewCount")
        appendLine("HASubs: $activeHaSubscriptionCount  Bridge: $activeMacBridgeConnectionCount  NotifBuf: $notificationListenerBufferSize")
        appendLine("StopReason: ${lastListenStopReason ?: "—"}")
        appendLine("Focus: ${lastAudioFocusEvent ?: "—"}")
        appendLine("LastOverlay: ${lastOverlayAttempt ?: "—"}")
        appendLine("OverlayBlock: ${lastOverlayBlockReason ?: "—"}")
        append("WdRestarts: $watchdogRestartCount")
    }.trimEnd()
}
