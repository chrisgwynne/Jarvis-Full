package com.jarvis.assistant.ui.settings.screens

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.ui.components.JarvisCard
import com.jarvis.assistant.ui.components.JarvisScreenScaffold
import com.jarvis.assistant.ui.components.SectionHeader
import com.jarvis.assistant.ui.theme.JarvisTokens

/**
 * Prominent disclosure screen shown before directing the user to grant
 * ACCESS_BACKGROUND_LOCATION.
 *
 * Google Play policy requires a full-screen (or dialog-equivalent)
 * disclosure that covers:
 *   1. What data is accessed (precise location in the background)
 *   2. Why it is needed (the specific features that use it)
 *   3. How it is used and whether it is shared
 *
 * This screen satisfies that requirement.  It is reached from
 * [PermissionsScreen] when the user taps the "Background Location" row.
 * The "Open Settings" button deep-links directly to the app's location
 * permission page where the user can choose "Allow all the time".
 */
@Composable
internal fun BackgroundLocationDisclosureScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current

    JarvisScreenScaffold(
        title = "Background Location",
        subtitle = "What Jarvis accesses and why",
        onBack = onBack,
        onClose = onClose,
    ) {
        // ── Disclosure statement ──────────────────────────────────────────
        JarvisCard {
            Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.md)) {
                Text(
                    text = "Jarvis accesses your precise location in the background to " +
                           "power location-triggered reminders and arrival/departure " +
                           "suggestions — for example, \"remind me when I get home\" or " +
                           "\"let me know when I arrive at the office\".",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "This access happens only when the feature is active. " +
                           "Your location is never shared with any third party — " +
                           "it is processed entirely on this device.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // ── Feature breakdown ─────────────────────────────────────────────
        SectionHeader(title = "Features that use background location")
        JarvisCard {
            Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.md)) {
                DisclosureFeatureRow(
                    icon = Icons.Filled.Schedule,
                    title = "Location reminders",
                    detail = "\"Remind me when I get home\" — triggers when you arrive at or leave a saved place.",
                )
                DisclosureFeatureRow(
                    icon = Icons.Filled.Place,
                    title = "Arrival suggestions",
                    detail = "Contextual suggestions when you arrive at work, home, or a saved location.",
                )
            }
        }

        // ── Privacy assurance ─────────────────────────────────────────────
        SectionHeader(title = "Privacy")
        JarvisCard {
            DisclosureFeatureRow(
                icon = Icons.Filled.Shield,
                title = "On-device only — never shared",
                detail = "Location data is used only to match geofence boundaries. " +
                         "It is never sent to Anthropic, OpenAI, or any other remote service.",
            )
        }

        Spacer(Modifier.height(JarvisTokens.Space.md))

        // ── CTA — redirect to system settings ────────────────────────────
        Button(
            onClick = {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // On Android 10+ the user must set "Allow all the time" themselves
                    // in the system location settings — we cannot request it directly.
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null),
                    )
                } else {
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null),
                    )
                }
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = JarvisTokens.Space.lg),
        ) {
            Icon(
                Icons.Filled.LocationOn,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(JarvisTokens.Space.sm))
            Text("Open Location Settings")
        }
    }
}

@Composable
private fun DisclosureFeatureRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    detail: String,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.sm),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .size(20.dp)
                .padding(top = 2.dp),
        )
        Spacer(Modifier.width(JarvisTokens.Space.md))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
