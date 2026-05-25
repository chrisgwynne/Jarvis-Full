package com.jarvis.assistant.ui.settings.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jarvis.assistant.ui.settings.SettingsCategory
import com.jarvis.assistant.ui.settings.SettingsCategoryRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTheme

/**
 * Developer Diagnostics — the single consolidated landing for every
 * diagnostic / debug / legacy raw-config screen in the app.
 *
 * Only reachable from the home screen when Developer Mode is on (the
 * `DeveloperDiagnostics` SettingsCategory is `developerOnly = true`).
 *
 * The screen is six collapsible sections.  Each section header expands /
 * collapses on tap; the body lists one row per existing diagnostic screen.
 * Tapping a row navigates to that screen through the standard Settings
 * NavHost — no behaviour change to the individual screens, they're just
 * no longer surfaced as separate top-level rows.
 *
 *   1. Connection — Mac Bridge, Mac Brain, raw Gateway/Bridge/Brain config
 *   2. Voice      — Voice diagnostics, Speech Latency, local diagnostics
 *   3. Vision     — Vision diagnostics, App Control diagnostics
 *   4. Routing    — Experimental flags, response preferences, FAQ
 *   5. Session    — Session diagnostics, Trust diagnostics
 *   6. Latency    — Speech Latency (also linked from Voice — surfaced
 *                   here so a perf engineer can find it directly)
 */
@Composable
internal fun DeveloperDiagnosticsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenCategory: (SettingsCategory) -> Unit,
) {
    SettingsScaffold(title = "Developer Diagnostics", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "Internals",
            body  = "These tools expose raw runtime state — connection counters, " +
                    "STT/TTS internals, routing traces and timing histograms. " +
                    "Useful for debugging; not needed for normal use.",
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Connection",
            subtitle = "Gateway, Mac Bridge and Mac Brain link state",
            entries  = listOf(
                SettingsCategory.ConnectionDiagnostics,
                SettingsCategory.MacBridgeDiagnostics,
                SettingsCategory.MacBrainDiagnostics,
                SettingsCategory.BrainGateway,
                SettingsCategory.MacBridge,
                SettingsCategory.MacBrain,
            ),
            onOpen   = onOpenCategory,
            initiallyExpanded = true,
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Voice",
            subtitle = "STT, wake detection, TTS providers and per-turn timings",
            entries  = listOf(
                SettingsCategory.VoiceDiagnostics,
                SettingsCategory.LocalDiagnostics,
                SettingsCategory.SpeechLatency,
            ),
            onOpen   = onOpenCategory,
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Vision",
            subtitle = "Camera capture, OCR pipeline and app-control accessibility",
            entries  = listOf(
                SettingsCategory.VisionDiagnostics,
                SettingsCategory.AppControlDiagnostics,
            ),
            onOpen   = onOpenCategory,
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Routing",
            subtitle = "Experimental flags, response preferences and command reference",
            entries  = listOf(
                SettingsCategory.ExperimentalFlags,
                SettingsCategory.ResponsePreferences,
                SettingsCategory.Faq,
            ),
            onOpen   = onOpenCategory,
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Session",
            subtitle = "Session state, active goals and trust scoring",
            entries  = listOf(
                SettingsCategory.SessionDiagnostics,
                SettingsCategory.TrustDiagnostics,
            ),
            onOpen   = onOpenCategory,
        )

        Spacer(Modifier.height(8.dp))

        DiagSection(
            title    = "Latency",
            subtitle = "Speech and pipeline timing histograms",
            entries  = listOf(
                SettingsCategory.SpeechLatency,
            ),
            onOpen   = onOpenCategory,
        )

        Spacer(Modifier.height(24.dp))
    }
}

/**
 * A single collapsible section.  Header tap toggles expansion; the body
 * is rendered as a standard [SettingsGroup] so visual style matches the
 * rest of the Settings UI.  Expanded state is keyed on the section
 * title so each section remembers its own state independently across
 * recomposition.
 */
@Composable
private fun DiagSection(
    title: String,
    subtitle: String,
    entries: List<SettingsCategory>,
    onOpen: (SettingsCategory) -> Unit,
    initiallyExpanded: Boolean = false,
) {
    var expanded by rememberSaveable(title) { mutableStateOf(initiallyExpanded) }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(SettingsTheme.GroupShape)
                .background(SettingsTheme.Surface)
                .clickable { expanded = !expanded }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text       = title,
                    color      = SettingsTheme.TextPrimary,
                    fontSize   = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text     = subtitle,
                    color    = SettingsTheme.TextMuted,
                    fontSize = 12.sp,
                )
            }
            Icon(
                imageVector       = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = if (expanded) "Collapse $title" else "Expand $title",
                tint               = SettingsTheme.TextMuted,
                modifier           = Modifier.size(22.dp),
            )
        }
        AnimatedVisibility(
            visible = expanded,
            enter   = expandVertically(),
            exit    = shrinkVertically(),
        ) {
            Column(modifier = Modifier.padding(top = 4.dp)) {
                SettingsGroup {
                    entries.forEachIndexed { idx, cat ->
                        SettingsCategoryRow(
                            icon        = cat.icon,
                            title       = cat.title,
                            description = cat.description,
                            onClick     = { onOpen(cat) },
                        )
                        if (idx < entries.lastIndex) SettingsRowDivider()
                    }
                }
            }
        }
    }
}
