package com.jarvis.assistant.reliability

import android.app.AppOpsManager
import android.content.Context
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log

/**
 * PermissionStateObserver — reacts to runtime permission revocations in real time.
 *
 * Registers:
 *  - A [ContentObserver] on [Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES]
 *  - A [ContentObserver] on the notification-listener secure setting
 *  - An [AppOpsManager.OnOpChangedListener] for SYSTEM_ALERT_WINDOW (API 29+)
 *
 * On any change, calls [HealthMonitor.refresh] so the live [HealthMonitor.health]
 * StateFlow emits an updated [HealthSnapshot].  [ServiceWatchdog] collects that
 * flow and reacts (show overlay warning, restart services, etc.).
 *
 * Call [start] in [com.jarvis.assistant.service.JarvisService.onCreate] and
 * [stop] in [com.jarvis.assistant.service.JarvisService.onDestroy].
 */
class PermissionStateObserver(context: Context) {

    companion object { private const val TAG = "PermissionStateObserver" }

    // Store applicationContext, not the service context.  The AppOpsManager callback and the
    // ContentObservers are registered for the process lifetime (revoked only in stop()), so
    // holding the service context here would keep the service instance alive through a leak
    // path: AppOpsManager$4.val$callback → lambda → context.  applicationContext is a
    // process-level singleton and carries no per-service lifetime.
    private val context: Context = context.applicationContext
    private val handler  = Handler(Looper.getMainLooper())
    private val resolver = this.context.contentResolver

    private val accessibilityObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            Log.d(TAG, "accessibility services setting changed")
            HealthMonitor.refresh(context)
        }
    }

    private val notificationObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            Log.d(TAG, "notification listeners setting changed")
            HealthMonitor.refresh(context)
        }
    }

    // Held so we can unregister on stop()
    private var overlayOpsCallback: AppOpsManager.OnOpChangedListener? = null

    fun start() {
        resolver.registerContentObserver(
            Settings.Secure.getUriFor(Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES),
            false,
            accessibilityObserver,
        )
        resolver.registerContentObserver(
            Settings.Secure.getUriFor("enabled_notification_listeners"),
            false,
            notificationObserver,
        )

        // AppOpsManager overlay watch (API 29+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val appOps = context.getSystemService(AppOpsManager::class.java) ?: return
            val cb = AppOpsManager.OnOpChangedListener { _, _ ->
                Log.d(TAG, "overlay op changed")
                HealthMonitor.refresh(context)
            }
            overlayOpsCallback = cb
            try {
                appOps.startWatchingMode(
                    AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW,
                    context.packageName,
                    cb,
                )
            } catch (e: Exception) {
                Log.w(TAG, "startWatchingMode failed: ${e.message}")
            }
        }

        Log.d(TAG, "started")
    }

    fun stop() {
        resolver.unregisterContentObserver(accessibilityObserver)
        resolver.unregisterContentObserver(notificationObserver)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            overlayOpsCallback?.let { cb ->
                try {
                    context.getSystemService(AppOpsManager::class.java)?.stopWatchingMode(cb)
                } catch (_: Exception) { /* best-effort */ }
            }
        }
        overlayOpsCallback = null

        Log.d(TAG, "stopped")
    }
}
