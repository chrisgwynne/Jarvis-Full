package com.jarvis.assistant.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.NotificationsNone
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Top-level groupings shown in the settings home screen.
 *
 * Declaration order = display order on the home screen.
 * Empty sections (all categories hidden or developerOnly) are skipped
 * automatically in [SettingsRootScreen].
 *
 * Sprint 5 changes:
 *  - Removed `Connections` — Home Assistant, Calendar and Todoist are now
 *    navigated from within Mac Integration.
 *  - Removed `AssistantBehaviour` — was empty after Sprint 4 category moves.
 *  - Reordered to match final target structure.
 */
internal enum class SettingsSection(
    val title: String,
    val icon: ImageVector,
) {
    VoiceListening(
        title = "Voice & Listening",
        icon  = Icons.Filled.RecordVoiceOver,
    ),
    /** Phone Control — formerly AppsActions. */
    AppsActions(
        title = "Phone Control",
        icon  = Icons.Filled.PhoneAndroid,
    ),
    MacIntegration(
        title = "Mac Integration",
        icon  = Icons.Filled.Psychology,
    ),
    NotificationsProactivity(
        title = "Notifications & Proactivity",
        icon  = Icons.Filled.NotificationsNone,
    ),
    PrivacyData(
        title = "Privacy & Data",
        icon  = Icons.Filled.Security,
    ),
    Appearance(
        title = "Appearance",
        icon  = Icons.Filled.Palette,
    ),
    SystemDiagnostics(
        title = "Developer & Diagnostics",
        icon  = Icons.Filled.Settings,
    ),
}
