package com.jarvis.assistant.ui.settings.screens

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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.remote.gateway.BrainGatewayWebSocketClient
import com.jarvis.assistant.remote.gateway.GatewayWsStatus
import com.jarvis.assistant.remote.gateway.TransportMode
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun BrainGatewaySettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenDiagnostics: (() -> Unit)? = null,
) {
    val repo        = JarvisApp.brainGatewaySettings
    var cfg         by remember { mutableStateOf(repo.snapshot()) }
    val wsStatus    by BrainGatewayWebSocketClient.sharedStatus.collectAsState()
    val testStatus  by vm.gatewayTestStatus.collectAsStateWithLifecycle()
    val pairStatus  by vm.gatewayPairStatus.collectAsStateWithLifecycle()

    var deviceName     by remember { mutableStateOf(cfg.deviceName) }
    var manualUrl      by remember { mutableStateOf("") }
    var manualCode     by remember { mutableStateOf("") }
    val migratedFrom = remember { repo.migratedFrom }

    SettingsScaffold(title = "Mac Brain Gateway", onBack = onBack, onClose = onClose) {

        // ── Status card ───────────────────────────────────────────────────────
        val (statusTitle, statusBody, accent, bg) = when {
            !cfg.isPaired && wsStatus == GatewayWsStatus.NotPaired ->
                StatusInfo(
                    "Not paired",
                    "Enter the Gateway URL and pairing code from Mac Jarvis to pair",
                    SettingsTheme.TextMuted, SettingsTheme.InfoBg,
                )
            wsStatus == GatewayWsStatus.Unauthorized ->
                StatusInfo(
                    "Token revoked",
                    "The session token was rejected. Enter a new pairing code to re-pair.",
                    SettingsTheme.Destructive, SettingsTheme.InfoBg,
                )
            wsStatus == GatewayWsStatus.Connected ->
                StatusInfo(
                    "Connected",
                    "Live command channel active on ${cfg.baseUrl}",
                    SettingsTheme.Success, SettingsTheme.SuccessBg,
                )
            wsStatus == GatewayWsStatus.Reconnecting ->
                StatusInfo(
                    "Reconnecting",
                    "Connection lost — retrying with backoff",
                    SettingsTheme.Cyan, SettingsTheme.InfoBg,
                )
            wsStatus == GatewayWsStatus.Connecting ->
                StatusInfo(
                    "Connecting",
                    "Opening WebSocket to ${cfg.baseUrl}",
                    SettingsTheme.Cyan, SettingsTheme.InfoBg,
                )
            cfg.isPaired ->
                StatusInfo(
                    "Paired",
                    "Paired with ${cfg.baseUrl}. Jarvis will connect on next start.",
                    SettingsTheme.TextMuted, SettingsTheme.InfoBg,
                )
            else ->
                StatusInfo(
                    "Not configured",
                    "Enter the Gateway URL and pairing code from Mac Jarvis to pair",
                    SettingsTheme.TextMuted, SettingsTheme.InfoBg,
                )
        }
        SettingsInfoCard(title = statusTitle, body = statusBody, accent = accent, background = bg)

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

        // ── Pairing ───────────────────────────────────────────────────────────
        if (!cfg.isPaired) {
            // Migration hint — shown when the URL was auto-derived from legacy settings
            val migratedSource = when (migratedFrom) {
                "bridge" -> "Mac Bridge"
                "brain"  -> "Mac Brain"
                else     -> null
            }
            if (migratedSource != null && cfg.baseUrl.isNotBlank()) {
                SettingsInfoCard(
                    body = "URL pre-filled from your $migratedSource settings. " +
                           "Enter the pairing code to pair — the gateway port may differ (default 8765).",
                )
                Spacer(Modifier.height(8.dp))
            }

            SettingsGroup(
                title  = "Pair with Mac Jarvis",
                footer = "On Mac: open Settings → Developer → Brain API → Generate Pairing Code. Enter the Gateway URL and the 6-digit code below.",
            ) {
                SettingsTextFieldRow(
                    title         = "Device name",
                    value         = deviceName,
                    onValueChange = { deviceName = it },
                    placeholder   = android.os.Build.MODEL,
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title         = "Gateway URL",
                    value         = manualUrl,
                    onValueChange = { manualUrl = it },
                    placeholder   = "http://100.x.x.x:8765",
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title         = "Pairing code",
                    value         = manualCode,
                    onValueChange = { manualCode = it.take(6) },
                    placeholder   = "6-digit code from Mac",
                )
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Pair",
                    description = "Enter the Gateway URL and 6-digit code above, then tap Pair.",
                    actionLabel = if (pairStatus == "Pairing…") "Pairing…" else "Pair",
                    onAction    = {
                        if (pairStatus != "Pairing…" && manualUrl.isNotBlank() && manualCode.length == 6) {
                            vm.completeGatewayPairing(manualUrl.trim(), manualCode.trim(), deviceName)
                        }
                    },
                )
            }
        } else {
            SettingsGroup(title = "Paired device") {
                SettingsValueRow(
                    title = "Gateway URL",
                    value = cfg.baseUrl.ifBlank { "—" },
                )
                SettingsRowDivider()
                SettingsTextFieldRow(
                    title         = "This device name",
                    value         = deviceName,
                    onValueChange = { v ->
                        deviceName = v
                        vm.setGatewayDeviceName(v)
                    },
                    placeholder   = android.os.Build.MODEL,
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Last connected",
                    value = formatTimestamp(cfg.lastConnectedAt),
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Last Mac activity",
                    value = formatTimestamp(cfg.lastSeenMacAt),
                )
            }
            Spacer(Modifier.height(8.dp))

            // ── Transport mode ────────────────────────────────────────────────
            SettingsGroup(
                title  = "Transport",
                footer = "Auto selects Tailscale when reachable, otherwise falls back to local network.",
            ) {
                TransportMode.entries.forEachIndexed { index, mode ->
                    SettingsToggleRow(
                        title           = mode.displayName,
                        description     = mode.description,
                        checked         = cfg.transportMode == mode,
                        onCheckedChange = { on ->
                            if (on) {
                                vm.setGatewayTransportMode(mode)
                                cfg = repo.snapshot()
                            }
                        },
                    )
                    if (index < TransportMode.entries.lastIndex) SettingsRowDivider()
                }
            }
            Spacer(Modifier.height(8.dp))

            // ── Unpair ────────────────────────────────────────────────────────
            SettingsGroup {
                SettingsActionRow(
                    title       = "Unpair",
                    description = "Removes the session token. Enter a new pairing code to re-pair.",
                    actionLabel = "Unpair",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Yes, unpair",
                    onAction    = {
                        vm.unpairGateway()
                        cfg = repo.snapshot()
                    },
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // ── Test connection ───────────────────────────────────────────────────
        SettingsGroup(title = "Connectivity") {
            SettingsActionRow(
                title       = "Test connection",
                description = testStatus ?: "Check if the gateway is reachable",
                actionLabel = if (testStatus == "Testing…") "Testing…" else "Test",
                onAction    = { if (testStatus != "Testing…") vm.testGatewayConnection() },
            )
        }

        if (onOpenDiagnostics != null) {
            Spacer(Modifier.height(8.dp))
            SettingsGroup {
                SettingsActionRow(
                    title       = "Gateway diagnostics",
                    description = "WebSocket status, pairing info, reconnect count",
                    actionLabel = "View",
                    onAction    = onOpenDiagnostics,
                )
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}

private data class StatusInfo(
    val title:  String,
    val body:   String,
    val accent: androidx.compose.ui.graphics.Color,
    val bg:     androidx.compose.ui.graphics.Color,
)

private val TransportMode.displayName: String get() = when (this) {
    TransportMode.Auto         -> "Auto"
    TransportMode.Tailscale    -> "Tailscale"
    TransportMode.LocalNetwork -> "Local Network"
}

private val TransportMode.description: String get() = when (this) {
    TransportMode.Auto         -> "Use Tailscale if available, otherwise local Wi-Fi"
    TransportMode.Tailscale    -> "Always route through Tailscale VPN"
    TransportMode.LocalNetwork -> "Always use local Wi-Fi or LAN"
}

private val sdf = SimpleDateFormat("d MMM HH:mm", Locale.getDefault())

private fun formatTimestamp(epochMs: Long?): String {
    if (epochMs == null || epochMs <= 0) return "Never"
    val age = System.currentTimeMillis() - epochMs
    return when {
        age < 60_000   -> "Just now"
        age < 3_600_000 -> "${age / 60_000}m ago"
        age < 86_400_000 -> "${age / 3_600_000}h ago"
        else             -> sdf.format(Date(epochMs))
    }
}
