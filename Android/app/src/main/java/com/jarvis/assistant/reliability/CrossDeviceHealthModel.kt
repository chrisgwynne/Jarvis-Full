package com.jarvis.assistant.reliability

import com.jarvis.assistant.core.state.JarvisState
import com.jarvis.assistant.core.store.DeviceStateStore
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.remote.brain.MacBrainStatus

/**
 * CrossDeviceHealthModel — a single aggregated snapshot of the cross-device system health.
 *
 * Reads from:
 *   - [MacBrainConnectionManager.sharedStatus] — WebSocket connection to the Mac brain daemon
 *   - [DeviceStateStore.current]               — runtime state (JarvisState, TTS, etc.)
 *   - [ListenerDiagnostics]                    — wake / listen active counters, last errors,
 *                                                pending remote route ID
 *
 * No business logic lives here — this is a pure read/aggregate layer so a UI component or
 * diagnostics overlay can call [snapshot] and get a coherent picture without knowing which
 * sub-system owns which piece of state.
 *
 * Thread safety: all source fields are @Volatile or StateFlow-backed; reads are safe from
 * any thread.  The returned [Snapshot] is an immutable value object.
 */
object CrossDeviceHealthModel {

    /**
     * Read a point-in-time health snapshot.  O(1), no I/O, no coroutines needed.
     */
    fun snapshot(): Snapshot {
        val gatewayStatus    = MacBrainConnectionManager.sharedStatus.value
        val deviceState      = DeviceStateStore.current
        val diag             = ListenerDiagnostics.snapshot()

        val macBrainOnline   = gatewayStatus == MacBrainStatus.Connected
        val gatewayConnected = macBrainOnline
        val degradedMode     = !macBrainOnline &&
                               gatewayStatus != MacBrainStatus.NotPaired &&
                               gatewayStatus != MacBrainStatus.Unauthorized &&
                               gatewayStatus != MacBrainStatus.Disconnected

        val wakeReady        = diag.activeWakeDetectorCount > 0
        val listenReady      = diag.activeSpeechRecognizerCount > 0
        val ttsReady         = !deviceState.ttsPlaying
        val daemonConnected  = macBrainOnline

        val lastRouteId      = diag.pendingRemoteRouteId
        val awaitingReplyMs  = if (diag.pendingRemoteRouteId != null) diag.awaitingRemoteReplySinceMs else 0L
        val lastError        = diag.lastListenStopReason

        return Snapshot(
            macBrainOnline      = macBrainOnline,
            gatewayStatus       = gatewayStatus,
            gatewayConnected    = gatewayConnected,
            wakeReady           = wakeReady,
            listenReady         = listenReady,
            ttsReady            = ttsReady,
            daemonConnected     = daemonConnected,
            degradedModeActive  = degradedMode,
            lastRouteId         = lastRouteId,
            awaitingReplySinceMs = awaitingReplyMs,
            lastError           = lastError,
            remoteReplyTimeouts = diag.remoteReplyTimeouts,
            runtimeState        = deviceState.runtimeState,
        )
    }

    // ── Snapshot ──────────────────────────────────────────────────────────────

    /**
     * Immutable cross-device health snapshot.
     *
     * @param macBrainOnline      True when the WebSocket to the Mac brain daemon is in
     *                            the [MacBrainStatus.Connected] state.
     * @param gatewayStatus       Raw status enum for finer-grained UI display.
     * @param gatewayConnected    Alias of [macBrainOnline], named for UI clarity.
     * @param wakeReady           Wake-word detector is running (idle wake phase active).
     * @param listenReady         Command-capture mic is open (Listening state).
     * @param ttsReady            TTS engine is not currently speaking (ready to play).
     * @param daemonConnected     Mac brain connection is open.
     * @param degradedModeActive  Gateway is configured but currently unreachable;
     *                            local fallback paths will be used for LLM reasoning.
     * @param lastRouteId         Route ID of the currently pending remote reply, or null.
     * @param awaitingReplySinceMs  Wall-clock epoch ms when AwaitingRemoteReply was entered;
     *                            0 if not waiting.
     * @param lastError           Last listen-stop reason (debugging / diagnostics).
     * @param remoteReplyTimeouts Cumulative count of 8-second remote reply timeouts.
     * @param runtimeState        The current JarvisState from the state machine.
     */
    data class Snapshot(
        val macBrainOnline:       Boolean,
        val gatewayStatus:        MacBrainStatus,
        val gatewayConnected:     Boolean,
        val wakeReady:            Boolean,
        val listenReady:          Boolean,
        val ttsReady:             Boolean,
        val daemonConnected:      Boolean,
        val degradedModeActive:   Boolean,
        val lastRouteId:          String?,
        val awaitingReplySinceMs: Long,
        val lastError:            String?,
        val remoteReplyTimeouts:  Int,
        val runtimeState:         JarvisState,
    ) {
        /** True when the device is in a healthy, ready-to-respond state. */
        val isHealthy: Boolean get() = macBrainOnline && wakeReady && ttsReady

        /** True when degraded mode is active (Mac unavailable, using local fallback). */
        val isFullyOffline: Boolean get() =
            gatewayStatus == MacBrainStatus.Disconnected ||
            gatewayStatus == MacBrainStatus.NotPaired

        /** A compact one-line status for overlay/debug display. */
        fun toOneLiner(): String = buildString {
            append("brain=${if (macBrainOnline) "online" else gatewayStatus.name.lowercase()}")
            append(" wake=${if (wakeReady) "✓" else "✗"}")
            append(" tts=${if (ttsReady) "✓" else "busy"}")
            if (degradedModeActive) append(" [DEGRADED]")
            if (lastRouteId != null) append(" pending=$lastRouteId")
            if (remoteReplyTimeouts > 0) append(" timeouts=$remoteReplyTimeouts")
        }
    }
}
