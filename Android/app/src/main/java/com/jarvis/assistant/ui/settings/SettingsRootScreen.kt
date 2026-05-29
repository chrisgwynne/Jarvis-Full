package com.jarvis.assistant.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.jarvis.assistant.remote.brain.MacBrainConnectionManager
import com.jarvis.assistant.remote.brain.MacBrainStatus
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.components.JarvisRowDivider
import com.jarvis.assistant.ui.components.JarvisSettingsGroup
import com.jarvis.assistant.ui.components.JarvisSettingsRow
import com.jarvis.assistant.ui.components.PillTag
import com.jarvis.assistant.ui.components.SectionHeader
import com.jarvis.assistant.ui.theme.JarvisGradients
import com.jarvis.assistant.ui.theme.JarvisTokens
import com.jarvis.assistant.ui.theme.jarvisExtras

/**
 * Settings home — the premium, simplified entry point.
 *
 * Per docs/SIMPLIFY_ANDROID_UX.md the root shows only the appliance-essential
 * sections: Mac connection, Voice, Permissions, Notifications, Troubleshooting
 * and About.  Brain-owned (Intelligence) and developer/diagnostic categories
 * are tagged `developerOnly` and never listed here — they remain reachable via
 * deep link / Developer Mode for engineers only.
 *
 * The screen is theme-aware (light-first); it no longer renders the old
 * System-Health diagnostic grid or a discoverable Developer-Mode toggle.
 */
@Composable
internal fun SettingsRootScreen(
    onOpenCategory: (SettingsCategory) -> Unit,
    onClose: () -> Unit,
    vm: SettingsViewModel = viewModel(),
) {
    val context        = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val devMode        by vm.developerModeEnabled.collectAsState()
    val macStatus      by MacBrainConnectionManager.sharedStatus.collectAsState()
    val scheme         = MaterialTheme.colorScheme
    val extras         = MaterialTheme.jarvisExtras

    // Re-check permission state on resume so the Permissions row subtitle is fresh.
    var micOk by remember { mutableStateOf(PermissionUtils.isMicrophoneGranted(context)) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                micOk = PermissionUtils.isMicrophoneGranted(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Visible categories = user-facing only (developerOnly == false).
    val visibleCategories = remember(devMode) {
        SettingsCategory.entries.filter { !it.developerOnly }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(JarvisGradients.lightBackdrop))
            .statusBarsPadding(),
    ) {
        // ── Top bar ────────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Settings",
                color = scheme.onBackground,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            Box(
                modifier = Modifier
                    .size(JarvisTokens.Touch.minTarget)
                    .clip(CircleShape)
                    .background(extras.surfaceRaised),
                contentAlignment = Alignment.Center,
            ) {
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = "Close settings", tint = scheme.onSurfaceVariant)
                }
            }
        }

        // ── Body ───────────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = JarvisTokens.Space.lg, vertical = JarvisTokens.Space.sm),
            verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.xl),
        ) {
            SettingsSection.entries.forEach { section ->
                // Never render the hidden developer bucket as a visible section.
                if (section == SettingsSection.SystemDiagnostics) return@forEach

                val items = visibleCategories.filter { it.section == section }
                if (items.isEmpty()) return@forEach

                Column(verticalArrangement = Arrangement.spacedBy(JarvisTokens.Space.sm)) {
                    SectionHeader(title = section.title, icon = section.icon)

                    JarvisSettingsGroup {
                        items.forEachIndexed { index, category ->
                            JarvisSettingsRow(
                                icon = category.icon,
                                title = category.title,
                                subtitle = subtitleFor(category, micOk),
                                onClick = { onOpenCategory(category) },
                                badge = {
                                    badgeFor(category, macStatus)?.let { (text, color) ->
                                        PillTag(text = text, color = color)
                                    }
                                },
                            )
                            if (index < items.lastIndex) JarvisRowDivider()
                        }
                    }
                }
            }

            Text(
                text = "Jarvis on this phone is a connector to your Mac. Intelligence, " +
                    "memory and advanced settings live on the Mac brain.",
                color = scheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = JarvisTokens.Space.xs),
            )

            Spacer(Modifier.height(JarvisTokens.Space.xl))
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

@Composable
private fun badgeFor(
    category: SettingsCategory,
    macStatus: MacBrainStatus,
): Pair<String, androidx.compose.ui.graphics.Color>? {
    val extras = MaterialTheme.jarvisExtras
    return when (category) {
        SettingsCategory.MacIntegration -> when (macStatus) {
            MacBrainStatus.Connected    -> "Connected" to extras.statusGreen
            MacBrainStatus.Connecting,
            MacBrainStatus.Reconnecting -> "Reconnecting" to extras.statusAmber
            MacBrainStatus.Unauthorized -> "Re-pair" to extras.statusRed
            MacBrainStatus.NotPaired    -> "Not paired" to extras.textMuted
            MacBrainStatus.Disconnected -> "Offline" to extras.textMuted
        }
        else -> null
    }
}

private fun subtitleFor(category: SettingsCategory, micOk: Boolean): String = when (category) {
    SettingsCategory.Voice ->
        if (micOk) category.description else "Microphone is blocked — tap to fix"
    else -> category.description
}
