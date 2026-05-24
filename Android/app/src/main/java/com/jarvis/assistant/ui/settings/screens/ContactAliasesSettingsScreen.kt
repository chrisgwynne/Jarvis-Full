package com.jarvis.assistant.ui.settings.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.jarvis.assistant.tools.ContactAliasStore
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsValueRow

@Composable
internal fun ContactAliasesSettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val store = remember { ContactAliasStore(context) }

    var version by remember { mutableStateOf(0) }
    val aliases = remember(version) { store.all() }

    var newAlias  by remember { mutableStateOf("") }
    var newTarget by remember { mutableStateOf("") }

    SettingsScaffold(title = "Contact aliases", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "How it works",
            body  = "Aliases let you call someone by a nickname. Add one below or " +
                    "say \"save wifey as Sarah\". Then \"message wifey\", \"call wifey\", " +
                    "or \"WhatsApp wifey\" all route to that contact."
        )

        SettingsGroup(
            title  = "Add alias",
            footer = "Target must exist in your contacts.  Aliases are case-insensitive.",
        ) {
            SettingsTextFieldRow(
                title         = "Alias",
                description   = "What you'll say: \"wifey\", \"mum\", \"the boss\"",
                value         = newAlias,
                onValueChange = { newAlias = it },
                placeholder   = "Nickname…",
            )
            SettingsRowDivider()
            SettingsTextFieldRow(
                title         = "Contact name",
                description   = "Real contact to map to",
                value         = newTarget,
                onValueChange = { newTarget = it },
                placeholder   = "e.g. Sarah Smith…",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Save alias",
                actionLabel = "Save",
                onAction    = {
                    val a = newAlias.trim()
                    val t = newTarget.trim()
                    if (a.isNotBlank() && t.isNotBlank()) {
                        store.save(a, t)
                        newAlias = ""
                        newTarget = ""
                        version++
                    }
                },
            )
        }

        if (aliases.isNotEmpty()) {
            SettingsGroup(
                title  = "Saved aliases",
                footer = "Tap remove on any alias you no longer want.",
            ) {
                aliases.forEachIndexed { index, (alias, target) ->
                    SettingsValueRow(title = alias, value = target)
                    SettingsRowDivider()
                    SettingsActionRow(
                        title       = "Remove $alias",
                        actionLabel = "Remove",
                        destructive = true,
                        confirm     = true,
                        confirmCopy = "Yes, remove",
                        onAction    = {
                            store.remove(alias)
                            version++
                        },
                    )
                    if (index < aliases.size - 1) SettingsRowDivider()
                }
            }
        }
    }
}
