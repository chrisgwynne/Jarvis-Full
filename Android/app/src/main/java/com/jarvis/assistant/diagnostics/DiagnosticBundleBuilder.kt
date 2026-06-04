package com.jarvis.assistant.diagnostics

import android.content.Context
import android.os.Build
import com.jarvis.assistant.BuildConfig
import com.jarvis.assistant.reliability.ListenerDiagnostics
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.ui.settings.PermissionUtils
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * #71: builds a **sanitised** diagnostic bundle the user can share with support.
 *
 * Contains ONLY non-content data: app/device/OS info, permission booleans,
 * Mac-brain connection state, listener counts, and per-route *outcomes*
 * (tool / intent / route / result / latency / remote-touched). It deliberately
 * NEVER includes transcripts, normalised text, slot values, message/contact/
 * calendar/location content, or any token — those fields on
 * [LocalRouteDiagnostics.Entry] are excluded here on purpose.
 */
object DiagnosticBundleBuilder {

    private const val MAX_ROUTES = 30

    /** Render the bundle as plain text. */
    fun build(context: Context): String = buildString {
        val now = System.currentTimeMillis()
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

        appendLine("Jarvis diagnostic bundle")
        appendLine("Generated: ${fmt.format(Date(now))}")
        appendLine()

        appendLine("## App")
        appendLine("version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
        appendLine("build: ${if (BuildConfig.DEBUG) "debug" else "release"}")
        appendLine("applicationId: ${BuildConfig.APPLICATION_ID}")
        appendLine()

        appendLine("## Device")
        appendLine("device: ${Build.MANUFACTURER} ${Build.MODEL}")
        appendLine("os: Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        appendLine()

        appendLine("## Permissions")
        appendLine("microphone: ${PermissionUtils.isMicrophoneGranted(context)}")
        appendLine("camera: ${PermissionUtils.isCameraGranted(context)}")
        appendLine("contacts: ${PermissionUtils.isContactsGranted(context)}")
        appendLine("calendar: ${PermissionUtils.isCalendarGranted(context)}")
        appendLine("location: ${PermissionUtils.isLocationGranted(context)}")
        appendLine("notificationListener: ${PermissionUtils.isNotificationListenerEnabled(context)}")
        appendLine("accessibility: ${PermissionUtils.isAccessibilityServiceEnabled(context)}")
        appendLine("overlays: ${PermissionUtils.canDrawOverlays(context)}")
        appendLine()

        appendLine("## Mac connection")
        appendLine("status: ${MacBrainConnectionManager.sharedStatus.value.name}")
        appendLine("remoteReplyTimeouts: ${ListenerDiagnostics.remoteReplyTimeouts.get()}")
        appendLine()

        appendLine("## Listeners")
        appendLine("wakeDetectors: ${ListenerDiagnostics.activeWakeDetectorCount.get()}")
        appendLine("speechRecognizers: ${ListenerDiagnostics.activeSpeechRecognizerCount.get()}")
        appendLine("overlayViews: ${ListenerDiagnostics.activeOverlayViewCount.get()}")
        appendLine("macBridgeConnections: ${ListenerDiagnostics.activeMacBridgeConnectionCount.get()}")
        appendLine("lastListenStopReason: ${ListenerDiagnostics.lastListenStopReason ?: "—"}")
        appendLine()

        appendLine("## Recent commands (outcomes only — no transcript content)")
        val routes = com.jarvis.assistant.diagnostics.LocalRouteDiagnostics.snapshot()
            .takeLast(MAX_ROUTES)
        if (routes.isEmpty()) {
            appendLine("(none recorded)")
        } else {
            routes.forEach { e ->
                appendLine(
                    "${fmt.format(Date(e.timestampMs))}  " +
                        "intent=${e.intent} tool=${e.tool} route=${e.route} " +
                        "result=${e.result} latency=${e.latencyMs}ms remote=${e.remoteTouched}"
                )
            }
        }
        appendLine()
        appendLine("(Sanitised: no transcripts, message/contact/calendar/location content, or tokens.)")
    }

    /**
     * Write the bundle to the app cache (under diagnostics/, exposed via the
     * FileProvider) and return the file for sharing.
     */
    fun writeToCache(context: Context): File {
        val dir = File(context.cacheDir, "diagnostics").apply { mkdirs() }
        val file = File(dir, "jarvis-diagnostics-${System.currentTimeMillis()}.txt")
        file.writeText(build(context))
        return file
    }
}
