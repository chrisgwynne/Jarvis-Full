package com.jarvis.assistant.reliability

import android.content.Context
import android.util.Log
import com.jarvis.assistant.overlay.JarvisOverlayService
import com.jarvis.assistant.overlay.OverlayEventBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * ServiceWatchdog — reacts to [HealthMonitor] state changes and keeps Jarvis alive.
 *
 * Responsibilities:
 *  1. Overlay service restart — when the overlay permission is granted but the
 *     service is not running (e.g. killed by OOM), restart it.
 *  2. Permission revocation warnings — when accessibility or notification-listener
 *     access is revoked at runtime, show a brief failure overlay so the user knows
 *     what stopped working and why.
 *
 * Each warning is shown exactly once per revocation event (edge-triggered on
 * the transition from granted → revoked, not level-triggered on each snapshot).
 *
 * Call [start] after [HealthMonitor.refresh] in
 * [com.jarvis.assistant.service.JarvisService.onCreate] and
 * [stop] in [com.jarvis.assistant.service.JarvisService.onDestroy].
 */
class ServiceWatchdog(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    companion object { private const val TAG = "ServiceWatchdog" }

    private var watchJob: Job? = null

    // Edge-trigger state — initialised from the current snapshot so we don't
    // fire "permission revoked" warnings for a state that was already missing
    // before this service instance was created.
    private var lastAccessibilityOk  = HealthMonitor.health.value.accessibilityEnabled
    private var lastNotificationOk   = HealthMonitor.health.value.notificationListenerEnabled
    private var lastOverlayGranted   = HealthMonitor.health.value.overlayGranted

    fun start() {
        watchJob = scope.launch {
            HealthMonitor.health
                .collect { snap -> react(snap) }
        }
        Log.d(TAG, "started")
    }

    fun stop() {
        watchJob?.cancel()
        watchJob = null
        Log.d(TAG, "stopped")
    }

    // ── Reaction logic ────────────────────────────────────────────────────────

    private fun react(snap: HealthSnapshot) {
        handleOverlay(snap)
        handleAccessibility(snap)
        handleNotificationListener(snap)
    }

    private fun handleOverlay(snap: HealthSnapshot) {
        // Permission just granted → restart service if it died
        if (snap.overlayGranted && !snap.overlayServiceRunning) {
            Log.i(TAG, "overlay: permission ok, service not running — restarting")
            JarvisOverlayService.startIfPermitted(context)
        }
        // Falling edge — permission revoked
        if (!snap.overlayGranted && lastOverlayGranted) {
            Log.w(TAG, "overlay permission revoked")
            OverlayEventBridge.failure(
                title    = "Overlay permission removed",
                message  = "Open Settings → Apps → Special access to restore.",
                dedupKey = "perm_overlay_revoked",
            )
        }
        lastOverlayGranted = snap.overlayGranted
    }

    private fun handleAccessibility(snap: HealthSnapshot) {
        if (!snap.accessibilityEnabled && lastAccessibilityOk) {
            Log.w(TAG, "accessibility service disabled")
            OverlayEventBridge.failure(
                title    = "Accessibility disabled",
                message  = "App control and on-screen commands are unavailable.",
                dedupKey = "perm_accessibility_revoked",
            )
        }
        lastAccessibilityOk = snap.accessibilityEnabled
    }

    private fun handleNotificationListener(snap: HealthSnapshot) {
        if (!snap.notificationListenerEnabled && lastNotificationOk) {
            Log.w(TAG, "notification listener disabled")
            OverlayEventBridge.failure(
                title    = "Notification access removed",
                message  = "Jarvis can no longer read your notifications.",
                dedupKey = "perm_notification_revoked",
            )
        }
        lastNotificationOk = snap.notificationListenerEnabled
    }
}
