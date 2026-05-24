package com.jarvis.assistant.ui.settings.screens

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
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.remote.macbridge.AndroidRole
import com.jarvis.assistant.remote.macbridge.EffectiveRole
import com.jarvis.assistant.remote.macbridge.MacBridgeClient
import com.jarvis.assistant.remote.macbridge.MacBridgeQrScanScreen
import com.jarvis.assistant.remote.macbridge.MacBridgeStatus
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow
import android.content.Intent
import com.jarvis.assistant.service.JarvisService
import com.jarvis.assistant.ui.camera.MacCameraViewerActivity
import com.jarvis.assistant.util.SettingsStore

@Composable
internal fun MacBridgeSettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenDiagnostics: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val store   = remember { SettingsStore(context) }
    val repo    = JarvisApp.macBridgeSettings
    val status  by MacBridgeClient.sharedStatus.collectAsState()

    var cfg            by remember { mutableStateOf(repo.snapshot()) }
    var showQr         by remember { mutableStateOf(false) }
    var cameraEnabled  by remember { mutableStateOf(store.macCameraEnabled) }
    var camUseBridge   by remember { mutableStateOf(store.macCameraUseBridgeCreds) }
    // Snapshot the role at composition time to detect mid-session changes.
    val macBridgeRoleAtStartup by remember { mutableStateOf(repo.snapshot().androidRole) }
    val arbitratorState by JarvisApp.roleArbitrator.state.collectAsState()

    if (showQr) {
        MacBridgeQrScanScreen(
            onResult = { host, port, auth ->
                val updated = cfg.copy(host = host, port = port, authToken = auth, enabled = true)
                repo.save(updated)
                cfg = updated
                showQr = false
                // Signal the runtime to (re)start the bridge
                com.jarvis.assistant.service.JarvisService.toggleMacBridge(context, true)
            },
            onCancel = { showQr = false },
        )
        return
    }

    SettingsScaffold(title = "Mac Bridge", onBack = onBack, onClose = onClose) {

        // ── Android role selector ─────────────────────────────────────────────
        SettingsGroup(title = "Android role") {
            AndroidRole.values().forEachIndexed { index, role ->
                SettingsToggleRow(
                    title       = role.displayName,
                    description = role.description,
                    checked     = cfg.androidRole == role,
                    onCheckedChange = { on ->
                        if (on) {
                            val updated = cfg.copy(androidRole = role)
                            repo.save(updated)
                            cfg = updated
                        }
                    },
                )
                if (index < AndroidRole.values().lastIndex) SettingsRowDivider()
            }
        }
        if (cfg.androidRole == AndroidRole.BRIDGE_ONLY && !JarvisService.isRunning(context)) {
            Spacer(Modifier.height(4.dp))
            SettingsInfoCard(body = "Bridge connects automatically when Jarvis starts.")
        }
        if (cfg.androidRole != AndroidRole.DISABLED &&
                cfg.androidRole != AndroidRole.AUTO &&
                macBridgeRoleAtStartup != AndroidRole.AUTO &&
                JarvisService.isRunning(context) &&
                cfg.androidRole != macBridgeRoleAtStartup) {
            Spacer(Modifier.height(4.dp))
            SettingsInfoCard(body = "Restart Jarvis for the new role to take effect.")
        }
        if (cfg.androidRole == AndroidRole.AUTO) {
            Spacer(Modifier.height(4.dp))
            SettingsGroup(title = "Auto role status") {
                val effectiveLabel = when (arbitratorState.effectiveRole) {
                    EffectiveRole.FULL_ASSISTANT -> "Full assistant"
                    EffectiveRole.BRIDGE_ONLY    -> "Bridge only"
                }
                SettingsValueRow(
                    title = "Effective role",
                    value = effectiveLabel,
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Reason",
                    value = arbitratorState.reason,
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Mac reachable",
                    value = if (arbitratorState.macReachable) "Yes" else "No",
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Mac assistant active",
                    value = if (arbitratorState.macAssistantActive) "Yes" else "No",
                )
                SettingsRowDivider()
                val ageLabel = when {
                    arbitratorState.lastActivityAgeMs < 0     -> "Never"
                    arbitratorState.lastActivityAgeMs < 1_000 -> "Just now"
                    arbitratorState.lastActivityAgeMs < 60_000 ->
                        "${arbitratorState.lastActivityAgeMs / 1_000}s ago"
                    else ->
                        "${arbitratorState.lastActivityAgeMs / 60_000}m ago"
                }
                SettingsValueRow(
                    title = "Last Mac activity",
                    value = ageLabel,
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Conversational owner",
                    value = arbitratorState.conversationalOwner
                        .replaceFirstChar { it.uppercaseChar() },
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // ── Status card ──────────────────────────────────────────────────────
        val statusLabel = when (status) {
            MacBridgeStatus.CONNECTED    -> "Connected"
            MacBridgeStatus.CONNECTING   -> "Connecting…"
            MacBridgeStatus.RECONNECTING -> "Reconnecting…"
            MacBridgeStatus.DISABLED     -> if (cfg.isConfigured) "Disabled" else "Not configured"
        }
        val statusBody = when {
            status == MacBridgeStatus.CONNECTED    ->
                "Mac Jarvis bridge live on ${cfg.host}:${cfg.port}"
            status == MacBridgeStatus.CONNECTING   ->
                "Opening WebSocket to ${cfg.host}:${cfg.port}"
            status == MacBridgeStatus.RECONNECTING ->
                "Connection lost — retrying with backoff"
            cfg.androidRole == AndroidRole.BRIDGE_ONLY && !cfg.isConfigured ->
                "Configure host and auth token to enable Bridge mode"
            cfg.isConfigured ->
                "Enable the toggle below to connect"
            else -> "Scan the QR code from Mac Jarvis to pair"
        }
        SettingsInfoCard(title = statusLabel, body = statusBody)

        // ── Bridge mode live status ───────────────────────────────────────────
        if (cfg.androidRole == AndroidRole.BRIDGE_ONLY) {
            Spacer(Modifier.height(4.dp))
            SettingsGroup {
                SettingsValueRow(
                    title       = "Listening",
                    value       = "Off",
                    description = "Android mic is disabled in Bridge mode",
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title       = "Speaking",
                    value       = "Off",
                    description = "Android TTS is disabled in Bridge mode",
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title       = "Last Mac command",
                    value       = MacBridgeClient.lastSharedInboundCommand.ifBlank { "—" },
                    description = "Most recent command received from Mac",
                )
                SettingsRowDivider()
                SettingsValueRow(
                    title       = "Last status",
                    value       = MacBridgeClient.lastSharedInboundStatus.ifBlank { "—" },
                    description = "Result of last executed command",
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // ── Master toggle ────────────────────────────────────────────────────
        SettingsGroup {
            SettingsToggleRow(
                title       = "Mac Bridge enabled",
                description = "Keep Android connected to Mac Jarvis over Tailscale",
                checked     = cfg.enabled,
                onCheckedChange = { enabled ->
                    val updated = cfg.copy(enabled = enabled)
                    repo.save(updated)
                    cfg = updated
                    com.jarvis.assistant.service.JarvisService.toggleMacBridge(context, enabled)
                },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Connection details ───────────────────────────────────────────────
        SettingsGroup {
            SettingsValueRow(
                title       = "Tailscale host",
                value       = cfg.host.ifBlank { "Not set" },
                description = "Mac's Tailscale IP (e.g. 100.91.42.7)",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Port",
                value       = cfg.port.toString(),
                description = "Default 17872",
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Auth token",
                value       = if (cfg.authToken.isBlank()) "Not set" else "••••••••",
                description = "Shared secret from Mac Jarvis",
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── QR pairing ───────────────────────────────────────────────────────
        SettingsGroup {
            com.jarvis.assistant.ui.settings.SettingsActionRow(
                title       = "Scan pairing QR",
                description = "Scan the QR code shown in Mac Jarvis to auto-configure",
                actionLabel = "Scan",
                onAction    = { showQr = true },
            )
            com.jarvis.assistant.ui.settings.SettingsRowDivider()
            com.jarvis.assistant.ui.settings.SettingsActionRow(
                title       = "Unpair",
                description = "Clears the host and auth token. Re-scan the QR code to re-pair.",
                actionLabel = "Unpair",
                destructive = true,
                confirm     = true,
                confirmCopy = "Yes, unpair",
                onAction    = {
                    repo.clearPairing()
                    cfg = repo.snapshot()
                    com.jarvis.assistant.service.JarvisService.toggleMacBridge(context, false)
                },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Event broadcasting ───────────────────────────────────────────────
        SettingsGroup(title = "Event broadcasting") {
            SettingsToggleRow(
                title           = "Send events to Mac",
                description     = "Stream calls, messages and device events to Mac Jarvis",
                checked         = cfg.eventsEnabled,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsEnabled = v).also { cfg = it }) },
            )
        }
        Spacer(Modifier.height(4.dp))
        SettingsGroup {
            SettingsToggleRow(
                title           = "Call events",
                description     = "Incoming calls, missed calls, answered and ended",
                checked         = cfg.eventsCalls,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsCalls = v).also { cfg = it }) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "SMS events",
                description     = "New text messages via SMS/Messages app",
                checked         = cfg.eventsSms,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsSms = v).also { cfg = it }) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "WhatsApp events",
                description     = "Incoming WhatsApp messages",
                checked         = cfg.eventsWhatsApp,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsWhatsApp = v).also { cfg = it }) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Other notifications",
                description     = "All other apps (opt-in — off by default)",
                checked         = cfg.eventsNotifications,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsNotifications = v).also { cfg = it }) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Battery & power events",
                description     = "Low battery, charging connected and disconnected",
                checked         = cfg.eventsBattery,
                onCheckedChange = { v -> repo.save(cfg.copy(eventsBattery = v).also { cfg = it }) },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Mac Camera ──────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Mac Camera",
            footer = "Camera URL and token details are shown in Bridge diagnostics.",
        ) {
            SettingsToggleRow(
                title           = "Enable Mac Camera Viewer",
                description     = "Say \"show me the Mac camera\" to open the live webcam",
                checked         = cameraEnabled,
                onCheckedChange = { v ->
                    cameraEnabled = v
                    store.macCameraEnabled = v
                },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Use Mac Bridge connection",
                description     = "Derive camera URL from Bridge host and reuse Bridge token",
                checked         = camUseBridge,
                onCheckedChange = { v ->
                    camUseBridge = v
                    store.macCameraUseBridgeCreds = v
                },
            )
            if (cameraEnabled) {
                SettingsRowDivider()
                com.jarvis.assistant.ui.settings.SettingsActionRow(
                    title       = "Open camera viewer",
                    description = "Test the live stream",
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
        Spacer(Modifier.height(8.dp))

        // ── Privacy ──────────────────────────────────────────────────────────
        SettingsGroup(title = "Privacy") {
            SettingsToggleRow(
                title           = "Share caller names",
                description     = "Include contact names with call events. Off = 'Incoming call'",
                checked         = cfg.shareCallerNames,
                onCheckedChange = { v -> repo.save(cfg.copy(shareCallerNames = v).also { cfg = it }) },
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Share message previews",
                description     = "Include message text with SMS and WhatsApp events",
                checked         = cfg.shareMsgPreviews,
                onCheckedChange = { v -> repo.save(cfg.copy(shareMsgPreviews = v).also { cfg = it }) },
            )
        }

        if (onOpenDiagnostics != null) {
            Spacer(Modifier.height(8.dp))
            com.jarvis.assistant.ui.settings.SettingsGroup {
                com.jarvis.assistant.ui.settings.SettingsActionRow(
                    title       = "Bridge diagnostics",
                    description = "Live status, event log, reconnect count and permission health",
                    actionLabel = "View",
                    onAction    = onOpenDiagnostics,
                )
            }
        }

        Spacer(Modifier.height(24.dp))
    }
}
