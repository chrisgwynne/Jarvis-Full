package com.jarvis.assistant.ui.settings.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.remote.brain.MacBrainStatus
import com.jarvis.assistant.ui.components.JarvisButton
import com.jarvis.assistant.ui.components.JarvisButtonStyle
import com.jarvis.assistant.ui.components.JarvisCard
import com.jarvis.assistant.ui.components.JarvisScreenScaffold
import com.jarvis.assistant.ui.theme.JarvisTheme
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras
import androidx.compose.foundation.background
import androidx.compose.runtime.collectAsState

/**
 * Troubleshooting — a single calm screen that replaces every diagnostics
 * screen for normal users (see docs/SIMPLIFY_ANDROID_UX.md).
 *
 * Five guided entries: Connection problem, Microphone problem, Permission
 * problem, Command failed, and Export diagnostic bundle.  Each expands to a
 * short, plain-language explanation and a single safe action.  Where a real
 * handler exists it is called (re-pair, open Permissions); otherwise the CTA
 * is a clearly-safe placeholder (the diagnostic-bundle export is stubbed until
 * `DiagnosticBundleBuilder` lands — see the deferred issue).
 */
@Composable
internal fun TroubleshootingScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenPermissions: () -> Unit,
    onOpenMacConnection: () -> Unit,
    onExportBundle: (() -> Unit)? = null,
) {
    val extras = MaterialTheme.jarvisExtras
    val macStatus by MacBrainConnectionManager.sharedStatus.collectAsState()

    val connectionDetail = when (macStatus) {
        MacBrainStatus.Connected    -> "Connected to your Mac. If something still isn't " +
            "working, try re-opening the Mac connection screen."
        MacBrainStatus.Connecting,
        MacBrainStatus.Reconnecting -> "Trying to reach your Mac. Make sure the Mac is awake, " +
            "on the same network, and running Jarvis."
        MacBrainStatus.Unauthorized -> "Your pairing was rejected. Re-pair from the Mac " +
            "connection screen to fix it."
        MacBrainStatus.NotPaired    -> "This phone isn't paired with a Mac yet. Open the Mac " +
            "connection screen and scan the QR code."
        MacBrainStatus.Disconnected -> "Not connected. Open the Mac connection screen to pair " +
            "or reconnect."
    }

    JarvisScreenScaffold(
        title = "Troubleshooting",
        subtitle = "Quick fixes for the most common problems. Each step is safe to try.",
        onBack = onBack,
        onClose = onClose,
    ) {
        TroubleshootEntry(
            icon = Icons.Filled.LinkOff,
            accent = extras.statusAmber,
            title = "Connection problem",
            detail = connectionDetail,
            ctaLabel = "Open Mac connection",
            onCta = onOpenMacConnection,
        )
        TroubleshootEntry(
            icon = Icons.Filled.MicOff,
            accent = extras.statusRed,
            title = "Microphone problem",
            detail = "Jarvis can't hear you if the microphone is blocked or in use by a phone " +
                "call. Check the microphone permission, then try pressing the talk button.",
            ctaLabel = "Check permissions",
            onCta = onOpenPermissions,
        )
        TroubleshootEntry(
            icon = Icons.Filled.Shield,
            accent = MaterialTheme.colorScheme.primary,
            title = "Permission problem",
            detail = "Some commands need a permission — calling, messaging, calendar or " +
                "location. Review what's granted and fix anything missing.",
            ctaLabel = "Open Permissions",
            onCta = onOpenPermissions,
        )
        TroubleshootEntry(
            icon = Icons.Filled.ErrorOutline,
            accent = extras.statusAmber,
            title = "Command failed",
            detail = "If Jarvis couldn't do something, it's usually a missing permission, an " +
                "app that wasn't installed, or a brief connection drop. Try the command " +
                "again — and check the connection and permissions above if it keeps failing.",
            ctaLabel = null,
            onCta = null,
        )
        TroubleshootEntry(
            icon = Icons.Filled.UploadFile,
            accent = extras.accentPurple,
            title = "Export diagnostic bundle",
            detail = "Create a sanitised report (app version, device, connection and recent " +
                "errors — no message or contact content) to share with support.",
            ctaLabel = "Export bundle",
            onCta = onExportBundle ?: {
                // Safe placeholder until DiagnosticBundleBuilder lands.
                // Intentionally a no-op so the control is never destructive.
            },
            ctaEnabled = onExportBundle != null,
            ctaNote = if (onExportBundle == null) "Coming soon" else null,
        )

        Text(
            text = "Need more detail? Developer diagnostics live on the Mac brain.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = JarvisTokens.Space.xs),
        )
    }
}

@Composable
private fun TroubleshootEntry(
    icon: ImageVector,
    accent: Color,
    title: String,
    detail: String,
    ctaLabel: String?,
    onCta: (() -> Unit)?,
    ctaEnabled: Boolean = true,
    ctaNote: String? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val extras = MaterialTheme.jarvisExtras
    var expanded by remember { mutableStateOf(false) }

    JarvisCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(JarvisTokens.Radius.md))
                    .background(accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.width(JarvisTokens.Space.md))
            Text(
                text = title,
                color = scheme.onSurface,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Icon(
                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = extras.textMuted,
            )
        }

        AnimatedVisibility(visible = expanded) {
            Column {
                Spacer(Modifier.size(JarvisTokens.Space.md))
                Text(
                    text = detail,
                    color = scheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (ctaLabel != null && onCta != null) {
                    Spacer(Modifier.size(JarvisTokens.Space.md))
                    JarvisButton(
                        text = ctaLabel,
                        onClick = onCta,
                        style = JarvisButtonStyle.Secondary,
                        enabled = ctaEnabled,
                    )
                    if (ctaNote != null) {
                        Spacer(Modifier.size(JarvisTokens.Space.xs))
                        Text(ctaNote, color = extras.textMuted, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}

@Preview(name = "Troubleshooting", showBackground = true, widthDp = 412, heightDp = 915)
@Composable
private fun PreviewTroubleshooting() {
    JarvisTheme {
        TroubleshootingScreen(
            onBack = {}, onClose = {},
            onOpenPermissions = {}, onOpenMacConnection = {},
        )
    }
}
