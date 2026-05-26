package com.jarvis.assistant.ui.settings.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
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
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.remote.brain.MacBrainStatus
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTheme
import com.jarvis.assistant.ui.settings.SettingsValueRow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Connection Diagnostics — raw internal state for Mac Brain connection.
 *
 * Developer-only screen (route: settings/connection_diagnostics).
 * Shows WebSocket status, pairing state, last activity, and permission status.
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

    // ── Mac Brain state ───────────────────────────────────────────────────────
    val wsStatus by MacBrainConnectionManager.sharedStatus.collectAsState()
    val brainCfg = remember { JarvisApp.macBrainConnectionManager.settingsRepo.snapshot() }
    val lastActivityAtMs = MacBrainConnectionManager.sharedLastActivityAtMs.get()

    // ── Brain diagnostics ─────────────────────────────────────────────────────
    val brainDiag by vm.brainDiagnostics.collectAsStateWithLifecycle()

    fun perm(name: String) =
        context.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    SettingsScaffold(title = "Connection Diagnostics", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "Raw connection state",
            body  = "Mac Brain connection status, counters and permission state.",
        )
        Spacer(Modifier.height(8.dp))

        // ══ MAC BRAIN — WS ════════════════════════════════════════════════════

        val (accent, bg) = when (wsStatus) {
            MacBrainStatus.Connected    -> SettingsTheme.Success     to SettingsTheme.SuccessBg
            MacBrainStatus.Unauthorized -> SettingsTheme.Destructive to SettingsTheme.InfoBg
            MacBrainStatus.Reconnecting,
            MacBrainStatus.Connecting   -> SettingsTheme.Cyan        to SettingsTheme.InfoBg
            else                        -> SettingsTheme.TextMuted   to SettingsTheme.InfoBg
        }
        SettingsInfoCard(
            title      = "Mac Brain — ${wsStatus.name}",
            body       = when (wsStatus) {
                MacBrainStatus.Connected    -> "WebSocket open. Commands and events flowing."
                MacBrainStatus.Reconnecting -> "Connection lost — reconnecting automatically."
                MacBrainStatus.Connecting   -> "Opening WebSocket connection."
                MacBrainStatus.Unauthorized -> "Token rejected. Re-pair to restore access."
                MacBrainStatus.NotPaired    -> "No pairing — connect via Mac Integration."
                else                        -> wsStatus.name
            },
            accent     = accent,
            background = bg,
        )
        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "Connection") {
            SettingsValueRow(
                title = "Status",
                value = wsStatus.name,
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Paired",
                value = if (brainCfg.isPaired) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Base URL",
                value = brainCfg.baseUrl.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Session token",
                value = if (brainCfg.deviceToken.isNullOrBlank()) "Not set" else "Present (masked)",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Device name",
                value = brainCfg.deviceName.ifBlank { "Not set" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Mac assistant active",
                value = if (MacBrainConnectionManager.sharedMacAssistantActive) "Yes" else "No",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last inbound command",
                value = MacBrainConnectionManager.lastSharedInboundCommand.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last inbound status",
                value = MacBrainConnectionManager.lastSharedInboundStatus.ifBlank { "—" },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title = "Last activity",
                value = fmt(lastActivityAtMs),
            )
        }
        Spacer(Modifier.height(8.dp))

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

        // ══ BRAIN ═════════════════════════════════════════════════════════════

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
        }

        Spacer(Modifier.height(24.dp))
    }
}
