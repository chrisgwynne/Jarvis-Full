package com.jarvis.assistant.ui.settings.screens

import android.content.Intent
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.remote.gateway.BrainGatewayQrScanScreen
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import com.jarvis.assistant.remote.gateway.GatewayWsStatus
import com.jarvis.assistant.remote.macbridge.MacBridgeClient
import com.jarvis.assistant.remote.macbridge.MacBridgeStatus
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.camera.MacCameraViewerActivity
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow
import com.jarvis.assistant.util.SettingsStore

/**
 * Mac Integration — single surface for everything Mac Jarvis.
 *
 * Sections (when paired):
 *  1. Status card — plain-language connection state
 *  2. Connection — test, device name, unpair
 *  3. Brain features — memory, project context, preferences
 *  4. Connected services — smart home, calendar, tasks (navigate to config)
 *  5. Mobile sync — calls/messages, notifications, battery
 *  6. Camera & Remote View — Mac webcam viewer
 *  7. Diagnostics link (developer only, shown when callback provided)
 *
 * All internal architecture details (ports, WebSocket URLs, session tokens,
 * transport modes, reconnect counters) are hidden here and live only in
 * Connection Diagnostics.
 */
@Composable
internal fun MacIntegrationScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenDiagnostics: (() -> Unit)? = null,
    onOpenHomeAssistant: (() -> Unit)? = null,
    onOpenCalendar: (() -> Unit)? = null,
    onOpenTodoist: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val store   = remember { SettingsStore(context) }

    // ── Gateway state ─────────────────────────────────────────────────────────
    val gatewayRepo = JarvisApp.brainGatewaySettings
    var gatewayCfg  by remember { mutableStateOf(gatewayRepo.snapshot()) }
    val wsStatus    by BrainGatewayWebSocketClient.sharedStatus.collectAsState()
    val testStatus  by vm.gatewayTestStatus.collectAsStateWithLifecycle()
    val pairStatus  by vm.gatewayPairStatus.collectAsStateWithLifecycle()
    var deviceName  by remember { mutableStateOf(gatewayCfg.deviceName) }
    var showQr      by remember { mutableStateOf(false) }

    // ── Mac Bridge state (Mobile Sync) ────────────────────────────────────────
    val bridgeRepo   = JarvisApp.macBridgeSettings
    var bridgeCfg    by remember { mutableStateOf(bridgeRepo.snapshot()) }
    val bridgeStatus by MacBridgeClient.sharedStatus.collectAsState()

    // ── Brain feature toggles ─────────────────────────────────────────────────
    val allowMemory      by vm.macBrainAllowMemory.collectAsStateWithLifecycle()
    val allowProject     by vm.macBrainAllowProject.collectAsStateWithLifecycle()
    val allowPreferences by vm.macBrainAllowPreferences.collectAsStateWithLifecycle()

    // ── Camera state ──────────────────────────────────────────────────────────
    var cameraEnabled by remember { mutableStateOf(store.macCameraEnabled) }

    // ── QR scan flow ──────────────────────────────────────────────────────────
    if (showQr) {
        BrainGatewayQrScanScreen(
            onResult = { url, code ->
                showQr = false
                vm.completeGatewayPairing(url, code, deviceName)
            },
            onCancel = { showQr = false },
        )
        return
    }

    SettingsScaffold(title = "Mac Integration", onBack = onBack, onClose = onClose) {

        // ── 1. Status card ────────────────────────────────────────────────────
        val isPaired = gatewayCfg.isPaired
        val (statusTitle, statusBody, accent, bg) = when {
            wsStatus == GatewayWsStatus.Unauthorized ->
                MacStatusInfo(
                    "Pair again required",
                    "Your session expired. Scan the QR code from Mac Jarvis to reconnect.",
                    SettingsTheme.Destructive, SettingsTheme.InfoBg,
                )
            wsStatus == GatewayWsStatus.Connected ->
                MacStatusInfo(
                    "Connected to Mac Jarvis",
                    "Commands, memory and context are active.",
                    SettingsTheme.Success, SettingsTheme.SuccessBg,
                )
            wsStatus == GatewayWsStatus.Reconnecting ->
                MacStatusInfo(
                    "Reconnecting…",
                    "Connection lost. Reconnecting automatically — no action needed.",
                    SettingsTheme.Cyan, SettingsTheme.InfoBg,
                )
            wsStatus == GatewayWsStatus.Connecting ->
                MacStatusInfo(
                    "Connecting to Mac Jarvis…",
                    "Opening connection.",
                    SettingsTheme.Cyan, SettingsTheme.InfoBg,
                )
            isPaired ->
                MacStatusInfo(
                    "Paired with Mac Jarvis",
                    "Jarvis will connect automatically when your Mac is available.",
                    SettingsTheme.TextMuted, SettingsTheme.InfoBg,
                )
            else ->
                MacStatusInfo(
                    "Not connected",
                    "Open Mac Jarvis and tap 'Pair Android device', then scan the QR code here.",
                    SettingsTheme.TextMuted, SettingsTheme.InfoBg,
                )
        }
        SettingsInfoCard(
            title      = statusTitle,
            body       = statusBody,
            accent     = accent,
            background = bg,
        )

        // Pairing feedback
        if (!pairStatus.isNullOrBlank()) {
            Spacer(Modifier.height(4.dp))
            val isError = pairStatus?.startsWith("Paired") == false && pairStatus != "Pairing…"
            Text(
                text     = pairStatus ?: "",
                color    = if (isError) SettingsTheme.Destructive else SettingsTheme.Success,
                fontSize = 13.sp,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Not paired: pairing flow ──────────────────────────────────────────
        if (!isPaired || wsStatus == GatewayWsStatus.Unauthorized) {
            SettingsGroup(
                title  = "Pair with Mac Jarvis",
                footer = "Open Mac Jarvis and go to Bridge → Show QR Code, then scan it here.",
            ) {
                SettingsTextFieldRow(
                    title         = "This device's name",
                    value         = deviceName,
                    onValueChange = { deviceName = it },
                    placeholder   = android.os.Build.MODEL,
                )
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Scan QR Code",
                    description = "Opens the camera to scan the QR code shown in Mac Jarvis",
                    actionLabel = if (pairStatus == "Pairing…") "Pairing…" else "Scan",
                    onAction    = { if (pairStatus != "Pairing…") showQr = true },
                )
            }
            Spacer(Modifier.height(24.dp))
            return@SettingsScaffold
        }

        // ── 2. Connection controls ────────────────────────────────────────────
        SettingsGroup(title = "Connection") {
            SettingsActionRow(
                title       = "Test connection",
                description = testStatus ?: "Check if Mac Jarvis is reachable",
                actionLabel = if (testStatus == "Testing…") "Testing…" else "Test",
                onAction    = { if (testStatus != "Testing…") vm.testGatewayConnection() },
            )
            SettingsRowDivider()
            SettingsTextFieldRow(
                title         = "This device's name",
                value         = deviceName,
                onValueChange = { v ->
                    deviceName = v
                    vm.setGatewayDeviceName(v)
                },
                placeholder   = android.os.Build.MODEL,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Unpair",
                description = "Removes the connection. Scan QR code to reconnect.",
                actionLabel = "Unpair",
                destructive = true,
                confirm     = true,
                confirmCopy = "Yes, unpair",
                onAction    = {
                    vm.unpairGateway()
                    gatewayCfg = gatewayRepo.snapshot()
                },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── 3. Brain features ─────────────────────────────────────────────────
        SettingsGroup(
            title  = "Brain Features",
            footer = "When connected, Mac Jarvis enriches responses with these capabilities.",
        ) {
            SettingsToggleRow(
                title           = "Memory & history",
                description     = "Recall past conversations and learned facts",
                checked         = allowMemory,
                onCheckedChange = vm::setMacBrainAllowMemory,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Project awareness",
                description     = "Current work context — code, open tasks, recent changes",
                checked         = allowProject,
                onCheckedChange = vm::setMacBrainAllowProject,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Preference sync",
                description     = "Your stored preferences and personalisation context",
                checked         = allowPreferences,
                onCheckedChange = vm::setMacBrainAllowPreferences,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── 4. Connected services ─────────────────────────────────────────────
        SettingsGroup(
            title  = "Connected services",
            footer = "Give Jarvis context about your home, schedule and tasks.",
        ) {
            SettingsActionRow(
                title       = "Smart home",
                description = if (vm.haConfigured)
                    "Home Assistant connected — control lights, climate and more by voice"
                else
                    "Control lights, switches, climate and scenes by voice",
                actionLabel = if (vm.haConfigured) "Manage" else "Set up",
                onAction    = { onOpenHomeAssistant?.invoke() },
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Calendar",
                description = "Give Jarvis your schedule for travel reminders and context-aware suggestions",
                actionLabel = "Manage",
                onAction    = { onOpenCalendar?.invoke() },
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Tasks & reminders",
                description = "Sync Todoist so you can manage your tasks by voice",
                actionLabel = "Manage",
                onAction    = { onOpenTodoist?.invoke() },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── 5. Mobile sync ────────────────────────────────────────────────────
        val isBridgeConnected = bridgeStatus == MacBridgeStatus.CONNECTED
        SettingsGroup(
            title  = "Mobile Sync",
            footer = if (!isBridgeConnected && bridgeCfg.isConfigured)
                "Sync connecting — will resume automatically."
            else if (!bridgeCfg.isConfigured)
                "Mobile sync will activate once the Mac connection is established."
            else null,
        ) {
            SettingsToggleRow(
                title           = "Calls & messages",
                description     = "Send call and message events to Mac Jarvis",
                checked         = bridgeCfg.eventsCalls || bridgeCfg.eventsSms ||
                                  bridgeCfg.eventsWhatsApp,
                onCheckedChange = { on ->
                    val updated = bridgeCfg.copy(
                        eventsCalls    = on,
                        eventsSms      = on,
                        eventsWhatsApp = on,
                    )
                    bridgeRepo.save(updated)
                    bridgeCfg = updated
                },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Notifications",
                description     = "Forward app notifications to Mac Jarvis",
                checked         = bridgeCfg.eventsNotifications,
                onCheckedChange = { on ->
                    val updated = bridgeCfg.copy(eventsNotifications = on)
                    bridgeRepo.save(updated)
                    bridgeCfg = updated
                },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Battery & device state",
                description     = "Let Mac Jarvis know your battery level and charging state",
                checked         = bridgeCfg.eventsBattery,
                onCheckedChange = { on ->
                    val updated = bridgeCfg.copy(eventsBattery = on)
                    bridgeRepo.save(updated)
                    bridgeCfg = updated
                },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── 6. Camera & Remote View ───────────────────────────────────────────
        SettingsGroup(
            title  = "Camera & Remote View",
            footer = "View your Mac's camera or share your phone's camera with Mac Jarvis.",
        ) {
            SettingsToggleRow(
                title           = "Mac camera viewer",
                description     = "Say \"show me the Mac camera\" to open the live webcam",
                checked         = cameraEnabled,
                onCheckedChange = { on ->
                    cameraEnabled = on
                    store.macCameraEnabled = on
                },
            )
            if (cameraEnabled) {
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Open camera viewer",
                    description = "Test the live Mac camera stream",
                    actionLabel = "Open",
                    onAction    = {
                        context.startActivity(
                            Intent(context, MacCameraViewerActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    },
                )
            }
        }

        // ── 7. Developer diagnostics link ─────────────────────────────────────
        if (onOpenDiagnostics != null) {
            Spacer(Modifier.height(8.dp))
            SettingsGroup {
                SettingsActionRow(
                    title       = "Connection diagnostics",
                    description = "Raw connection state, request counters and bridge logs",
                    actionLabel = "View",
                    onAction    = onOpenDiagnostics,
                )
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}

private data class MacStatusInfo(
    val title:  String,
    val body:   String,
    val accent: androidx.compose.ui.graphics.Color,
    val bg:     androidx.compose.ui.graphics.Color,
)
