package com.jarvis.assistant.ui.settings

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat

internal object PermissionUtils {

    // ── Runtime permission checkers ───────────────────────────────────────

    fun isGranted(ctx: Context, permission: String) =
        ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    fun isMicrophoneGranted(ctx: Context)  = isGranted(ctx, Manifest.permission.RECORD_AUDIO)
    fun isCameraGranted(ctx: Context)      = isGranted(ctx, Manifest.permission.CAMERA)
    fun isContactsGranted(ctx: Context)    = isGranted(ctx, Manifest.permission.READ_CONTACTS)
    fun isCalendarGranted(ctx: Context)    = isGranted(ctx, Manifest.permission.READ_CALENDAR)
    fun isLocationGranted(ctx: Context)    = isGranted(ctx, Manifest.permission.ACCESS_FINE_LOCATION)

    fun isBackgroundLocationGranted(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return isLocationGranted(ctx)
        return isGranted(ctx, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    }

    // ── Special permission checkers ───────────────────────────────────────

    fun isNotificationListenerEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
            ?: return false
        return flat.contains(ctx.packageName)
    }

    fun isAccessibilityServiceEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return flat.contains(ctx.packageName)
    }

    fun canDrawOverlays(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

    // ── Intent launchers ──────────────────────────────────────────────────

    fun openPermissionSettings(ctx: Context, perm: PermissionHealth) {
        val intent: Intent = when (perm.id) {
            "accessibility" ->
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "notification_listener" ->
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            "overlay" ->
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.fromParts("package", ctx.packageName, null),
                )
            else ->
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", ctx.packageName, null),
                )
        }
        ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // ── List builder ──────────────────────────────────────────────────────

    fun buildPermissionList(ctx: Context): List<PermissionHealth> = listOf(
        PermissionHealth(
            id       = "microphone",
            name     = "Microphone",
            detail   = "Core voice input — Jarvis cannot hear you without this",
            granted  = isMicrophoneGranted(ctx),
            required = true,
        ),
        PermissionHealth(
            id       = "accessibility",
            name     = "Accessibility Service",
            detail   = "App control, close-app commands and on-screen context",
            granted  = isAccessibilityServiceEnabled(ctx),
            required = true,
        ),
        PermissionHealth(
            id       = "notification_listener",
            name     = "Notification Access",
            detail   = "Read and summarise your notifications",
            granted  = isNotificationListenerEnabled(ctx),
            required = true,
        ),
        PermissionHealth(
            id       = "overlay",
            name     = "Draw Over Apps",
            detail   = "Progress overlay and confirmation dialogs",
            granted  = canDrawOverlays(ctx),
            required = true,
        ),
        PermissionHealth(
            id       = "contacts",
            name     = "Contacts",
            detail   = "Look up contacts to call, message or navigate to",
            granted  = isContactsGranted(ctx),
            required = true,
        ),
        PermissionHealth(
            id       = "calendar",
            name     = "Calendar",
            detail   = "Read upcoming events for reminders and briefings",
            granted  = isCalendarGranted(ctx),
            required = false,
        ),
        PermissionHealth(
            id       = "location",
            name     = "Location",
            detail   = "Navigation, commute time and local search",
            granted  = isLocationGranted(ctx),
            required = false,
        ),
        PermissionHealth(
            id       = "camera",
            name     = "Camera",
            detail   = "Vision analysis and OCR scan",
            granted  = isCameraGranted(ctx),
            required = false,
        ),
        PermissionHealth(
            id       = "background_location",
            name     = "Background Location",
            detail   = "Location-triggered reminders (e.g. remind me when I get home)",
            granted  = isBackgroundLocationGranted(ctx),
            required = false,
        ),
    )
}
