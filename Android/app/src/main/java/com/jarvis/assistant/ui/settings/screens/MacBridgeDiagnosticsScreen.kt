package com.jarvis.assistant.ui.settings.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.remote.macbridge.MacBridgeSettingsRepository
import com.jarvis.assistant.remote.maccamera.HttpMacCameraClient
import com.jarvis.assistant.util.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.jarvis.assistant.remote.macbridge.AndroidEventBroadcaster
import com.jarvis.assistant.remote.macbridge.MacBridgeClient
import com.jarvis.assistant.remote.macbridge.MacBridgeStatus
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsValueRow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun MacBridgeDiagnosticsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val status  by MacBridgeClient.sharedStatus.collectAsState()
    val diag    by AndroidEventBroadcaster.diagnostics.collectAsState()
    val cfg     = JarvisApp.macBridgeSettings.snapshot()

    val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    // Camera diagnostics state
    val store          = remember { SettingsStore(context) }
    var camHealthOk    by remember { mutableStateOf<Boolean?>(null) }
    val cameraEnabled  = store.macCameraEnabled
    val cameraToken    = if (store.macCameraUseBridgeCreds) cfg.authToken else store.macCameraAuthToken
    val cameraUrl      = remember {
        val client = HttpMacCameraClient(
            store,
            MacBridgeSettingsRepository(store)
        )
        client.streamUrl()
    }

    // Trigger a background health check when the diagnostics screen opens
    LaunchedEffect(Unit) {
        val client = HttpMacCameraClient(store, MacBridgeSettingsRepository(store))
        val result = client.health()
        camHealthOk = result is com.jarvis.assistant.remote.maccamera.MacCameraResult.HealthResult.Healthy
    }

    fun perm(name: String) =
        context.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    SettingsScaffold(title = "Mac Bridge Diagnostics", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "Live bridge state",
            body  = "Real-time status of the Android–Mac bridge, last event, " +
                    "reconnect count and permission states.",
        )
        Spacer(Modifier.height(8.dp))

        // ── Connection ────────────────────────────────────────────────────────
        SettingsGroup(title = "Connection") {
            SettingsValueRow(
                title = "Status",
                value = status.name.lowercase().replace('_', ' '),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Host",
                value = cfg.host.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Port",
                value = cfg.port.toString(),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Reconnect count",
                value = diag.reconnectCount.toString(),
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Events ────────────────────────────────────────────────────────────
        SettingsGroup(title = "Event broadcasting") {
            SettingsValueRow(
                title = "Broadcasting enabled",
                value = if (diag.eventsEnabled) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last event",
                value = diag.lastEventCommand.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last sent",
                value = if (diag.lastEventSentAt > 0L)
                    timeFmt.format(Date(diag.lastEventSentAt))
                else "—",
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Permissions ───────────────────────────────────────────────────────
        SettingsGroup(title = "Permissions") {
            SettingsValueRow(
                title = "Notification listener",
                value = if (JarvisNotificationListener.isGranted(context)) "Granted" else "Not granted",
                description = if (!JarvisNotificationListener.isGranted(context))
                    "Required to forward notifications to Mac. Grant via Settings → Notification access." else null,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Notification listener connected",
                value = if (JarvisNotificationListener.isConnected()) "Connected" else "Disconnected",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Read contacts",
                value = if (perm(Manifest.permission.READ_CONTACTS)) "Granted" else "Not granted",
                description = if (!perm(Manifest.permission.READ_CONTACTS))
                    "Required to resolve caller names. Grant via Settings → App permissions." else null,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Read phone state",
                value = if (perm(Manifest.permission.READ_PHONE_STATE)) "Granted" else "Not granted",
                description = if (!perm(Manifest.permission.READ_PHONE_STATE))
                    "Required for call event monitoring. Grant via Settings → App permissions." else null,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Reconnect warning ─────────────────────────────────────────────────
        if (diag.reconnectCount >= 3) {
            SettingsInfoCard(
                title = "Connection failures (${diag.reconnectCount}x)",
                body  = "The bridge has failed to connect ${diag.reconnectCount} times. " +
                        "Check that the auth token on this phone matches the one in " +
                        "Mac Jarvis Settings -> Network. Unpair and re-scan the QR code " +
                        "if the tokens are out of sync.",
            )
            Spacer(Modifier.height(8.dp))
        }

        // ── Debug ─────────────────────────────────────────────────────────────
        SettingsGroup(title = "Debug") {
            SettingsActionRow(
                title       = "Send test event",
                description = "Fires a synthetic incoming_call event to Mac. " +
                              "Mac should announce: Test Caller is calling. " +
                              "Bridge must be connected first.",
                actionLabel = "Send test incoming_call",
                onAction    = { AndroidEventBroadcaster.sendTestIncomingCall() },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Active event sources ──────────────────────────────────────────────
        SettingsGroup(title = "Active event sources") {
            val repo = JarvisApp.macBridgeSettings
            val c    = repo.snapshot()
            SettingsValueRow(title = "Call events",         value = if (c.eventsCalls)         "On" else "Off")
            SettingsRowDivider()
            SettingsValueRow(title = "SMS events",          value = if (c.eventsSms)           "On" else "Off")
            SettingsRowDivider()
            SettingsValueRow(title = "WhatsApp events",     value = if (c.eventsWhatsApp)      "On" else "Off")
            SettingsRowDivider()
            SettingsValueRow(title = "Other notifications", value = if (c.eventsNotifications) "On" else "Off")
            SettingsRowDivider()
            SettingsValueRow(title = "Battery events",      value = if (c.eventsBattery)       "On" else "Off")
        }
        Spacer(Modifier.height(8.dp))

        // ── Mac Camera diagnostics ────────────────────────────────────────────
        SettingsGroup(title = "Mac Camera") {
            SettingsValueRow(
                title = "Enabled",
                value = if (cameraEnabled) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Health reachable",
                value = when (camHealthOk) {
                    true  -> "Yes"
                    false -> "No"
                    null  -> "Checking…"
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Stream URL",
                value = if (cameraUrl.isBlank()) "Not configured"
                        else cameraUrl.replace(Regex("://[^@/]+@"), "://***@"),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Token",
                value = if (cameraToken.isBlank()) "Not set" else "Present (masked)",
            )
        }
    }
}
