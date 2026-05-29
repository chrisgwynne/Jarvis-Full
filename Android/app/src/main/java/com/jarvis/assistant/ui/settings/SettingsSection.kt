package com.jarvis.assistant.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.BuildCircle
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Top-level groupings shown on the settings home screen.
 *
 * Declaration order = display order.  Empty sections are skipped in
 * [SettingsRootScreen].
 *
 * ## 2026 simplification (see docs/SIMPLIFY_ANDROID_UX.md)
 *
 * Android is a connector/client for the Mac brain, so the visible root is
 * reduced to the appliance-essential set:
 *
 *   - Mac connection   — connect/pair + status + device identity
 *   - Voice            — microphone + Jarvis's spoken voice
 *   - Permissions      — one place for all Android permission state
 *   - Notifications    — alerts + status
 *   - Troubleshooting  — single calm screen replacing all diagnostics
 *   - About            — version, help, what Jarvis can do
 *
 * The former **Intelligence** (model/provider/persona/memory internals) and
 * **Developer & Diagnostics** sections are intentionally NOT listed here —
 * the brain owns that configuration.  Those categories still exist and their
 * screens remain reachable via deep link / Developer Mode, but they no longer
 * appear in normal navigation.  [SystemDiagnostics] is retained ONLY as the
 * bucket those hidden, developer-only categories are tagged with so the root
 * filter skips them; it is never rendered as a visible section.
 */
internal enum class SettingsSection(
    val title: String,
    val icon: ImageVector,
) {
    MacIntegration(
        title = "Mac connection",
        icon  = Icons.Filled.Psychology,
    ),
    VoiceListening(
        title = "Voice",
        icon  = Icons.Filled.RecordVoiceOver,
    ),
    Permissions(
        title = "Permissions",
        icon  = Icons.Filled.Shield,
    ),
    Notifications(
        title = "Notifications",
        icon  = Icons.Filled.Notifications,
    ),
    Troubleshooting(
        title = "Troubleshooting",
        icon  = Icons.Filled.BuildCircle,
    ),
    About(
        title = "About",
        icon  = Icons.AutoMirrored.Filled.HelpOutline,
    ),

    /**
     * Hidden bucket for developer-only / brain-owned categories.  Never shown
     * as a section; exists so those categories have a [SettingsSection] to be
     * tagged with and are filtered out of the visible root.
     */
    SystemDiagnostics(
        title = "Developer & Diagnostics",
        icon  = Icons.Filled.Settings,
    ),
}
