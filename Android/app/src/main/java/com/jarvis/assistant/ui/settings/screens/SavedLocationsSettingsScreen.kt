package com.jarvis.assistant.ui.settings.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.jarvis.assistant.location.SavedLocationsStore
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsValueRow

@Composable
internal fun SavedLocationsSettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val store = remember { SavedLocationsStore(context) }

    // Refresh trigger — bump this to re-read the store after any save/remove.
    var version by remember { mutableStateOf(0) }
    val allLabels = remember(version) { store.allLabels().sorted() }

    var homeAddress by remember { mutableStateOf(store.getHome()?.address ?: "") }
    var workAddress by remember { mutableStateOf(store.getWork()?.address ?: "") }

    // Custom-place add form
    var newLabel   by remember { mutableStateOf("") }
    var newAddress by remember { mutableStateOf("") }

    SettingsScaffold(title = "Saved Locations", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "How it works",
            body  = "Set Home, Work, and any custom places like the gym or mum's. " +
                    "Say \"navigate home\", \"how long until I'm at the gym\", or " +
                    "\"save this as gym\" while standing there to capture the address " +
                    "from your current location."
        )

        // ── HOME ─────────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Home",
            footer = "Used by \"navigate home\", \"directions home\", \"how long until I'm home\".",
        ) {
            SettingsTextFieldRow(
                title         = "Home address",
                description   = "e.g. 10 Downing Street, London SW1A 2AA",
                value         = homeAddress,
                onValueChange = { homeAddress = it },
                placeholder   = "Enter home address…",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Save home",
                actionLabel = "Save",
                onAction    = {
                    if (homeAddress.isNotBlank()) {
                        store.setHome(homeAddress.trim())
                        version++
                    }
                },
            )
            if (store.getHome() != null) {
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Saved",
                    value = store.getHome()?.address ?: "",
                )
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Clear home address",
                    actionLabel = "Clear",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Yes, clear",
                    onAction    = {
                        store.remove(SavedLocationsStore.LABEL_HOME)
                        homeAddress = ""
                        version++
                    },
                )
            }
        }

        // ── WORK ─────────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Work",
            footer = "Used by \"navigate to work\", \"directions to work\", ETA queries.",
        ) {
            SettingsTextFieldRow(
                title         = "Work address",
                description   = "e.g. 1 Infinite Loop, Cupertino, CA",
                value         = workAddress,
                onValueChange = { workAddress = it },
                placeholder   = "Enter work address…",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Save work",
                actionLabel = "Save",
                onAction    = {
                    if (workAddress.isNotBlank()) {
                        store.setWork(workAddress.trim())
                        version++
                    }
                },
            )
            if (store.getWork() != null) {
                SettingsRowDivider()
                SettingsValueRow(
                    title = "Saved",
                    value = store.getWork()?.address ?: "",
                )
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Clear work address",
                    actionLabel = "Clear",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Yes, clear",
                    onAction    = {
                        store.remove(SavedLocationsStore.LABEL_WORK)
                        workAddress = ""
                        version++
                    },
                )
            }
        }

        // ── CUSTOM PLACES ────────────────────────────────────────────────────
        val customLabels = allLabels.filter {
            it != SavedLocationsStore.LABEL_HOME && it != SavedLocationsStore.LABEL_WORK
        }
        SettingsGroup(
            title  = "Custom places",
            footer = "Add by typing below, or say \"save this place as gym\" while " +
                     "standing there — the current GPS fix is captured automatically.",
        ) {
            SettingsTextFieldRow(
                title         = "Label",
                description   = "What you'll call it: \"gym\", \"mum's\", \"the cottage\"",
                value         = newLabel,
                onValueChange = { newLabel = it },
                placeholder   = "Enter label…",
            )
            SettingsRowDivider()
            SettingsTextFieldRow(
                title         = "Address",
                description   = "Or leave blank to set with voice while standing there",
                value         = newAddress,
                onValueChange = { newAddress = it },
                placeholder   = "Enter address (optional)…",
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Add custom place",
                actionLabel = "Add",
                onAction    = {
                    val label = newLabel.trim().lowercase()
                    val addr  = newAddress.trim()
                    if (label.isNotBlank() && addr.isNotBlank() &&
                        label != SavedLocationsStore.LABEL_HOME &&
                        label != SavedLocationsStore.LABEL_WORK
                    ) {
                        store.save(label, addr)
                        newLabel = ""
                        newAddress = ""
                        version++
                    }
                },
            )

            customLabels.forEach { label ->
                val place = store.get(label) ?: return@forEach
                SettingsRowDivider()
                SettingsValueRow(
                    title = label.replaceFirstChar { it.titlecase() },
                    value = place.address,
                )
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Remove $label",
                    actionLabel = "Remove",
                    destructive = true,
                    confirm     = true,
                    confirmCopy = "Yes, remove",
                    onAction    = {
                        store.remove(label)
                        version++
                    },
                )
            }
        }
    }
}
