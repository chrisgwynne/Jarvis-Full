package com.jarvis.assistant.ui.settings.screens

import androidx.compose.runtime.Composable
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold

@Composable
internal fun MemorySettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    SettingsScaffold(title = "Memory", onBack = onBack, onClose = onClose) {
        SettingsGroup(
            title = "Stored data",
            footer = "Both actions are permanent and can't be undone.",
        ) {
            SettingsActionRow(
                title       = "Conversation history",
                description = "Raw dialogue logs — does not remove learned preferences or profile facts.",
                actionLabel = "Clear conversation history",
                destructive = true,
                confirm     = true,
                confirmCopy = "Clear history",
                onAction    = vm::clearConversationHistory,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Learned memories",
                description = "Everything Jarvis remembers about you — preferences, facts and summaries.",
                actionLabel = "Clear all memories",
                destructive = true,
                confirm     = true,
                confirmCopy = "Clear memories",
                onAction    = vm::clearAllMemories,
            )
        }
    }
}
