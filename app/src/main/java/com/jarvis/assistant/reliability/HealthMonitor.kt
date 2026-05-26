package com.jarvis.assistant.reliability

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * HealthMonitor — live snapshot of every permission and service Jarvis depends on.
 *
 * Refreshed by [PermissionStateObserver] on every Settings change and by
 * [ServiceWatchdog] on service lifecycle events.  The UI and [ServiceWatchdog]
 * collect [health] to show warnings or trigger restarts without polling.
 */
data class HealthSnapshot(
    val micGranted: Boolean                  = false,
    val overlayGranted: Boolean              = false,
    val accessibilityEnabled: Boolean        = false,
    val notificationListenerEnabled: Boolean = false,
    val overlayServiceRunning: Boolean       = false,
    val timestampMs: Long                    = 0L,
) {
    /** True when every permission Jarvis needs to function fully is satisfied. */
    val allCriticalOk: Boolean
        get() = micGranted && overlayGranted && accessibilityEnabled && notificationListenerEnabled
}

object HealthMonitor {

    private val _health = MutableStateFlow(HealthSnapshot())
    val health: StateFlow<HealthSnapshot> = _health.asStateFlow()

    /**
     * Re-evaluate every permission and store a fresh [HealthSnapshot].
     * Safe to call from any thread; all reads are thread-safe.
     */
    fun refresh(context: Context) {
        val ctx = context.applicationContext
        _health.value = HealthSnapshot(
            micGranted                   = ctx.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
            overlayGranted               = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx),
            accessibilityEnabled         = isAccessibilityEnabled(ctx),
            notificationListenerEnabled  = isNotificationListenerEnabled(ctx),
            overlayServiceRunning        = _health.value.overlayServiceRunning,
            timestampMs                  = System.currentTimeMillis(),
        )
    }

    /** Called by [com.jarvis.assistant.overlay.JarvisOverlayService] on create/destroy. */
    fun setOverlayServiceRunning(running: Boolean) {
        _health.value = _health.value.copy(overlayServiceRunning = running, timestampMs = System.currentTimeMillis())
    }

    // ── Internal checkers ─────────────────────────────────────────────────────

    private fun isAccessibilityEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return flat.contains(ctx.packageName, ignoreCase = true)
    }

    private fun isNotificationListenerEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(
            ctx.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return flat.contains(ctx.packageName, ignoreCase = true)
    }
}
