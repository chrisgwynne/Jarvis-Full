package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.JarvisApp
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsToggleRow

/**
 * Camera & Vision — unified screen replacing VisionSettingsScreen as the primary
 * surface.  WearablesSettingsScreen remains as a sub-screen for SDK diagnostics,
 * registration and firmware flows linked via [onOpenWearables].
 *
 * Removed from this surface (moved to developer/sub-screen):
 *  - OCR toggle (internal, never user-visible in practice)
 *  - Auto-fallback to phone camera (implementation detail, not a user choice)
 *  - Visual memory retention slider (advanced; defaults are fine for all users)
 *  - All wearables diagnostics (Connect/Disconnect/Capture test → sub-screen)
 */
@Composable
internal fun CameraVisionScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenWearables: () -> Unit,
) {
    val visionEnabled      by vm.visionEnabled.collectAsStateWithLifecycle()
    val preferPhoneCamera  by vm.preferPhoneCamera.collectAsStateWithLifecycle()
    val screenshotAnalysis by vm.screenshotAnalysisEnabled.collectAsStateWithLifecycle()
    val screenshotListener by vm.screenshotListenerEnabled.collectAsStateWithLifecycle()
    val saveVisualContext  by vm.saveVisualContext.collectAsStateWithLifecycle()

    val wearablesRepo  = JarvisApp.wearablesSettings
    val wearablesState by wearablesRepo.stateFlow.collectAsState()

    SettingsScaffold(title = "Camera & Vision", onBack = onBack, onClose = onClose) {

        // ── Camera ────────────────────────────────────────────────────────────
        SettingsGroup(title = "Camera") {
            SettingsToggleRow(
                title           = "Vision enabled",
                description     = "Allow Jarvis to analyse images from the camera or screenshots.",
                checked         = visionEnabled,
                onCheckedChange = vm::setVisionEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Prefer phone camera",
                description     = "Use the phone camera for 'look at this' commands " +
                                  "instead of Meta glasses when both are available.",
                checked         = preferPhoneCamera,
                onCheckedChange = vm::setPreferPhoneCamera,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Screenshots ───────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Screenshots",
            footer = "The screenshot listener watches your screenshot folder so follow-up " +
                     "commands like 'read that' or 'what does that say' work automatically.",
        ) {
            SettingsToggleRow(
                title           = "Screenshot analysis",
                description     = "Analyse screenshots when you say 'look at my screen'.",
                checked         = screenshotAnalysis,
                onCheckedChange = vm::setScreenshotAnalysisEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Screenshot listener",
                description     = "Watch for new screenshots and load them into visual context " +
                                  "automatically.",
                checked         = screenshotListener,
                onCheckedChange = vm::setScreenshotListenerEnabled,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Visual memory ─────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Visual memory",
            footer = "Visual context is held in memory for follow-up commands. " +
                     "Saved context is available across sessions.",
        ) {
            SettingsToggleRow(
                title           = "Save visual context",
                description     = "Persist recent visual observations for use across sessions.",
                checked         = saveVisualContext,
                onCheckedChange = vm::setSaveVisualContext,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Clear visual history",
                description = "Remove all stored visual observations from this device.",
                actionLabel = "Clear",
                destructive = true,
                confirm     = true,
                confirmCopy = "Clear",
                onAction    = { /* VisualContextStore.clear() wired at runtime via ToolRegistry */ },
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Meta glasses ──────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Meta glasses",
            footer = "When enabled, Jarvis can capture from the glasses for 'look at this' " +
                     "and 'read this'. Off by default — privacy first.",
        ) {
            SettingsToggleRow(
                title           = "Meta Wearables enabled",
                description     = "Master switch. Off keeps the glasses module dormant.",
                checked         = wearablesState.enabled,
                onCheckedChange = wearablesRepo::setEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Auto-connect on Jarvis start",
                description     = "Attempt a glasses connection during runtime startup.",
                checked         = wearablesState.autoConnectOnStart,
                onCheckedChange = wearablesRepo::setAutoConnectOnStart,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Use glasses for 'look at this'",
                description     = "Prefer the glasses camera for visual context requests.",
                checked         = wearablesState.useForLookAtThis,
                onCheckedChange = wearablesRepo::setUseForLookAtThis,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Save captures to gallery",
                description     = "Write glasses photos to the system gallery.",
                checked         = wearablesState.saveCapturesToGallery,
                onCheckedChange = wearablesRepo::setSaveCapturesToGallery,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Glasses setup & diagnostics",
                description = "Registration, permissions, firmware updates and connection testing.",
                actionLabel = "Configure",
                onAction    = onOpenWearables,
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}
