package com.jarvis.assistant.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Top-level groupings shown in the settings home screen.
 *
 * Declaration order = display order on the home screen.
 * Empty sections (all categories hidden or developerOnly) are skipped
 * automatically in [SettingsRootScreen].
 *
 * The final shape is 5 user-visible sections + 1 developer-only:
 *   - Voice            (1 row : Voice)
 *   - Conversation     (2 rows: Conversation, Messaging)
 *   - Intelligence     (5 rows: AI Provider, Ambient Intelligence,
 *                       Memory, Trust & Autonomy, Vision)
 *   - Mac Integration  (1 row : Mac Integration)
 *   - About            (1 row : About & Help)
 *   - Developer &
 *     Diagnostics      (1 row : Developer Diagnostics, dev-only)
 */
internal enum class SettingsSection(
    val title: String,
    val icon: ImageVector,
) {
    VoiceListening(
        title = "Voice",
        icon  = Icons.Filled.RecordVoiceOver,
    ),
    Conversation(
        title = "Conversation",
        icon  = Icons.Filled.ChatBubbleOutline,
    ),
    Intelligence(
        title = "Intelligence",
        icon  = Icons.Filled.Tune,
    ),
    MacIntegration(
        title = "Mac Integration",
        icon  = Icons.Filled.Psychology,
    ),
    About(
        title = "About",
        icon  = Icons.AutoMirrored.Filled.HelpOutline,
    ),
    SystemDiagnostics(
        title = "Developer & Diagnostics",
        icon  = Icons.Filled.Settings,
    ),
}
