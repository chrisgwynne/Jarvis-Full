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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import com.jarvis.assistant.remote.gateway.GatewayWsStatus
import com.jarvis.assistant.remote.macbridge.AndroidEventBroadcaster
import com.jarvis.assistant.remote.macbridge.MacBridgeClient
import com.jarvis.assistant.remote.macbridge.MacBridgeSettingsRepository
import com.jarvis.assistant.remote.maccamera.HttpMacCameraClient
import com.jarvis.assistant.remote.maccamera.MacCameraResult
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsValueRow
import com.jarvis.assistant.util.SettingsStore
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Connection Diagnostics — raw internal state for Gateway, Bridge and Brain.
 *
 * Developer-only screen (route: settings/connection_diagnostics).
 * Replaces the three separate diagnostics screens that previously lived behind
 * the legacy Mac Bridge, Mac Brain and Brain Gateway settings entries.
 *
 * Normal users never reach this screen — it's only navigable from the
 * "Connection diagnostics" row inside Mac Integration when Developer Mode
 * is enabled.
 */
@Composable
internal fun ConnectionDiagnosticsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    fun fmt(epochMs: Long) = if (epochMs > 0L) timeFmt.format(Date(epochMs)) else "—"

    // ── Gateway ───────────────────────────────────────────────────────────────
    val wsStatus   by BrainGatewayWebSocketClient.sharedStatus.collectAsState()
    val gatewayCfg = remember { JarvisApp.brainGatewaySettings.snapshot() }

    // ── Bridge ────────────────────────────────────────────────────────────────
    val bridgeStatus by MacBridgeClient.sharedStatus.collectAsState()
    val bridgeDiag   by AndroidEventBroadcaster.diagnostics.collectAsState()
    val bridgeCfg    = JarvisApp.macBridgeSettings.snapshot()

    // ── Brain ─────────────────────────────────────────────────────────────────
    val brainDiag by vm.brainDiagnostics.collectAsStateWithLifecycle()

    // ── Camera ────────────────────────────────────────────────────────────────
    val store         = remember { SettingsStore(context) }
    var camHealthOk   by remember { mutableStateOf<Boolean?>(null) }
    val cameraEnabled = store.macCameraEnabled
    val cameraToken   = if (store.macCameraUseBridgeCreds) bridgeCfg.authToken else store.macCameraAuthToken
    val cameraUrl     = remember {
        HttpMacCameraClient(store, MacBridgeSettingsRepository(store)).streamUrl()
    }
    LaunchedEffect(Unit) {
        val result = HttpMacCameraClient(store, MacBridgeSettingsRepository(store)).health()
        camHealthOk = result is MacCameraResult.HealthResult.Healthy
    }

    fun perm(name: String) =
        context.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    SettingsScaffold(title = "Connection Diagnostics", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "Raw connection state",
            body  = "Gateway, Bridge and Brain status — counters, logs and health state.",
        )
        Spacer(Modifier.height(8.dp))

        // ══ GATEWAY ═══════════════════════════════════════════════════════════

        SettingsGroup(title = "Gateway — WebSocket") {
            SettingsValueRow(
                title = "Status",
                value = when (wsStatus) {
                    GatewayWsStatus.Connected    -> "Connected"
                    GatewayWsStatus.Reconnecting -> "Reconnecting"
                    GatewayWsStatus.Connecting   -> "Connecting"
                    GatewayWsStatus.Unauthorized -> "Unauthorized (re-pair needed)"
                    else                         -> wsStatus.name
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Paired",
                value = if (gatewayCfg.isPaired) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Base URL",
                value = gatewayCfg.baseUrl.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Session token",
                value = if (gatewayCfg.sessionToken.isNullOrBlank()) "Not set" else "Present (masked)",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Mac assistant active",
                value = if (BrainGatewayWebSocketClient.sharedMacAssistantActive) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Device name",
                value = gatewayCfg.deviceName.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last inbound command",
                value = BrainGatewayWebSocketClient.lastSharedInboundCommand.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last inbound status",
                value = BrainGatewayWebSocketClient.lastSharedInboundStatus.ifBlank { "—" },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ══ BRIDGE ════════════════════════════════════════════════════════════

        SettingsGroup(title = "Bridge — Connection") {
            SettingsValueRow(
                title = "Status",
                value = bridgeStatus.name.lowercase().replace('_', ' '),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Host",
                value = bridgeCfg.host.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Port",
                value = bridgeCfg.port.toString(),
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Reconnect count",
                value = bridgeDiag.reconnectCount.toString(),
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Bridge — Event broadcasting") {
            SettingsValueRow(
                title = "Broadcasting enabled",
                value = if (bridgeDiag.eventsEnabled) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last event",
                value = bridgeDiag.lastEventCommand.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last sent",
                value = if (bridgeDiag.lastEventSentAt > 0L)
                    timeFmt.format(Date(bridgeDiag.lastEventSentAt))
                else "—",
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Bridge — Permissions") {
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

        if (bridgeDiag.reconnectCount >= 3) {
            SettingsInfoCard(
                title = "Bridge failures (${bridgeDiag.reconnectCount}x)",
                body  = "The bridge has failed to connect ${bridgeDiag.reconnectCount} times. " +
                        "Check that the auth token matches the one in Mac Jarvis Settings → Network. " +
                        "Unpair and re-scan if out of sync.",
            )
            Spacer(Modifier.height(8.dp))
        }

        SettingsGroup(title = "Bridge — Debug") {
            SettingsActionRow(
                title       = "Send test event",
                description = "Fires a synthetic incoming_call to Mac. " +
                              "Mac should announce: Test Caller is calling.",
                actionLabel = "Send test incoming_call",
                onAction    = { AndroidEventBroadcaster.sendTestIncomingCall() },
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Bridge — Active event sources") {
            val c = JarvisApp.macBridgeSettings.snapshot()
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

        SettingsGroup(title = "Bridge — Mac Camera") {
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
        Spacer(Modifier.height(8.dp))

        // ══ BRAIN ═════════════════════════════════════════════════════════════

        val (brainAccent, brainBg) = when {
            !brainDiag.enabled               -> SettingsTheme.TextMuted   to SettingsTheme.InfoBg
            brainDiag.lastHealthOk == true   -> SettingsTheme.Success     to SettingsTheme.SuccessBg
            brainDiag.lastHealthOk == false  -> SettingsTheme.Destructive to SettingsTheme.InfoBg
            brainDiag.circuitState == "OPEN" -> SettingsTheme.Destructive to SettingsTheme.InfoBg
            else                             -> SettingsTheme.Cyan        to SettingsTheme.InfoBg
        }
        SettingsInfoCard(
            title = when {
                !brainDiag.enabled               -> "Brain — Disabled"
                brainDiag.circuitState == "OPEN" -> "Brain — Connection paused"
                brainDiag.lastHealthOk == true   -> "Brain — Connected"
                brainDiag.lastHealthOk == false  -> "Brain — Unreachable"
                else                             -> "Brain — Configured"
            },
            body = when {
                !brainDiag.enabled               -> "Mac Brain is off. No context fetches will occur."
                brainDiag.circuitState == "OPEN" -> "Health tripped after repeated failures. Paused. Reset below."
                brainDiag.lastHealthOk == true   -> "Last check passed at ${brainDiag.lastHealthLatencyMs} ms. " +
                                                    "${brainDiag.totalSuccesses} successful fetches."
                brainDiag.lastHealthOk == false  -> "Last check failed. Verify the server address and access key."
                else                             -> "Brain enabled but no health check has run yet."
            },
            accent     = brainAccent,
            background = brainBg,
        )
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Status") {
            SettingsValueRow(
                title = "Enabled",
                value = if (brainDiag.enabled) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Connection health",
                value = when (brainDiag.circuitState) {
                    "CLOSED"    -> "Connected"
                    "OPEN"      -> "Paused"
                    "HALF_OPEN" -> "Recovering"
                    else        -> brainDiag.circuitState
                },
                description = when (brainDiag.circuitState) {
                    "CLOSED"    -> "Normal operation — requests flow through."
                    "OPEN"      -> "Paused — Brain fetches suppressed until recovery window expires."
                    "HALF_OPEN" -> "Recovering — one request will test reachability."
                    else        -> null
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "In-flight requests",
                value       = brainDiag.inFlightCount.toString(),
                description = "Requests currently awaiting a Brain response.",
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Health check") {
            SettingsValueRow(
                title = "Last result",
                value = when (brainDiag.lastHealthOk) {
                    true  -> "Passed"
                    false -> "Failed"
                    null  -> "Never checked"
                },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last latency",
                value = if (brainDiag.lastHealthLatencyMs >= 0L) "${brainDiag.lastHealthLatencyMs} ms" else "—",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last checked at",
                value = fmt(brainDiag.lastHealthCheckedAt),
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Last request") {
            SettingsValueRow(title = "Intent",         value = brainDiag.lastRequestIntent)
            SettingsRowDivider()
            SettingsValueRow(title = "Result",         value = brainDiag.lastRequestResult)
            SettingsRowDivider()
            SettingsValueRow(title = "Failure reason", value = brainDiag.lastFailureReason)
            SettingsRowDivider()
            SettingsValueRow(title = "Last succeeded", value = fmt(brainDiag.lastSucceededAt))
            SettingsRowDivider()
            SettingsValueRow(title = "Last cache hit", value = fmt(brainDiag.lastCacheHitAt))
            SettingsRowDivider()
            SettingsValueRow(title = "Last timeout",   value = fmt(brainDiag.lastTimeoutAt))
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Request counters") {
            SettingsValueRow(title = "Total requests", value = brainDiag.totalRequests.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Succeeded",      value = brainDiag.totalSuccesses.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Cache hits",     value = brainDiag.totalCacheHits.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Timeouts",       value = brainDiag.totalTimeouts.toString())
            SettingsRowDivider()
            SettingsValueRow(title = "Failures",       value = brainDiag.totalFailures.toString())
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Skipped",
                value       = brainDiag.totalSkipped.toString(),
                description = "Skipped by connection health, interrupt detection, or permission gate.",
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Memory cache") {
            SettingsValueRow(
                title       = "Cached entries",
                value       = brainDiag.cacheSize.toString(),
                description = "In-memory cache, max 64 entries, 5-min TTL.",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Clear cache",
                description = "Removes all cached Brain responses. Safe at any time.",
                actionLabel = "Clear",
                onAction    = vm::clearBrainCache,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Connection health") {
            SettingsValueRow(
                title       = "Status",
                value       = when (brainDiag.circuitState) {
                    "CLOSED"    -> "Connected"
                    "OPEN"      -> "Paused"
                    "HALF_OPEN" -> "Recovering"
                    else        -> brainDiag.circuitState
                },
                description = "Pauses after 5 failures in 2 min. Auto-recovers after 5 min.",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Reset connection health",
                description = "Forces Brain back to active. Use once the service is reachable again.",
                actionLabel = "Reset",
                onAction    = vm::resetBrainCircuit,
            )
        }
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Brain — Pending sync") {
            SettingsValueRow(
                title       = "Pending events",
                value       = brainDiag.pendingSyncCount.toString(),
                description = "Interaction outcomes queued for Mac Brain.",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Failed retries",
                value       = brainDiag.failedRetryCount.toString(),
                description = "Events that have failed at least once and are awaiting retry.",
            )
            SettingsRowDivider()
            SettingsValueRow(title = "Oldest queued at",  value = fmt(brainDiag.oldestQueuedAt))
            SettingsRowDivider()
            SettingsValueRow(title = "Last sync attempt", value = fmt(brainDiag.lastSyncAttemptAt))
            SettingsRowDivider()
            SettingsValueRow(title = "Last sync success", value = fmt(brainDiag.lastSyncSuccessAt))
            SettingsRowDivider()
            SettingsValueRow(title = "Last sync failure", value = fmt(brainDiag.lastSyncFailureAt))
        }

        Spacer(Modifier.height(24.dp))
    }
}
