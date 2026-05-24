package com.jarvis.assistant.overlay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.util.Log

/**
 * OverlayPermission — helpers for the SYSTEM_ALERT_WINDOW special permission.
 *
 * Unlike most runtime permissions this one is granted in Settings, not via a
 * dialog.  [hasPermission] checks the current grant; [openSettings] opens the
 * per-app overlay settings page so the user can grant it.
 *
 * The permission is required before [JarvisOverlayService] can add a view to
 * [android.view.WindowManager] with TYPE_APPLICATION_OVERLAY.
 */
object OverlayPermission {

    private const val TAG = "OverlayPermission"

    fun hasPermission(context: Context): Boolean =
        Settings.canDrawOverlays(context)

    /**
     * Open the system overlay-permission page for Jarvis so the user can grant it.
     * No-op when the permission is already granted.
     */
    fun openSettings(context: Context) {
        if (hasPermission(context)) return
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            Log.d(TAG, "opened overlay-permission settings")
        } catch (e: Exception) {
            Log.e(TAG, "failed to open overlay settings: ${e.message}")
        }
    }
}
