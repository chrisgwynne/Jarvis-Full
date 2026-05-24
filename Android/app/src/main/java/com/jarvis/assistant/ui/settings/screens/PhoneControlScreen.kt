package com.jarvis.assistant.ui.settings.screens

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.notifications.JarvisNotificationListener
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.PermissionHealthCard
import com.jarvis.assistant.ui.settings.PermissionUtils
import com.jarvis.assistant.ui.settings.SettingsActionRow
import com.jarvis.assistant.ui.settings.SettingsDropdownRow
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow
import com.jarvis.assistant.ui.settings.SettingsToggleRow
import com.jarvis.assistant.ui.settings.SettingsValueRow

/**
 * Phone Control — unified screen replacing the former Conversation, App Control,
 * Actions & Apps, Messaging and Navigation sub-screens.
 *
 * Sub-screens with dynamic lists (Routines, Contact Aliases, Saved Locations)
 * remain as separate routes and are linked from here via navigation callbacks.
 *
 * ROLE MODEL (visible to user)
 * ─────────────────────────────
 * "Jarvis controls the phone."  One screen.  Not seven disconnected action subsystems.
 */
@Composable
internal fun PhoneControlScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onOpenRoutines: () -> Unit,
    onOpenContactAliases: () -> Unit,
    onOpenSavedLocations: () -> Unit,
) {
    val context        = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // ── Messaging ─────────────────────────────────────────────────────────────
    val defaultChannel by vm.defaultMsgChannel.collectAsStateWithLifecycle()
    val channels = listOf(
        "ask" to "Ask each time",
        "sms" to "SMS",
        "whatsapp" to "WhatsApp",
    )
    val selectedChannel = channels.firstOrNull { it.first == defaultChannel } ?: channels.first()

    // ── App control ───────────────────────────────────────────────────────────
    val appControlEnabled    by vm.appControlEnabled.collectAsStateWithLifecycle()
    val accessibilityControl by vm.allowAccessibilityAppControl.collectAsStateWithLifecycle()
    val allowAppClose        by vm.allowAppClose.collectAsStateWithLifecycle()

    // ── Brave Search ──────────────────────────────────────────────────────────
    val braveKey by vm.braveSearchApiKey.collectAsStateWithLifecycle()

    // ── Permissions (refresh on resume) ───────────────────────────────────────
    var permissions by remember { mutableStateOf(PermissionUtils.buildPermissionList(context)) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissions = PermissionUtils.buildPermissionList(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val notifGranted   = JarvisNotificationListener.isGranted(context)
    val notifConnected = JarvisNotificationListener.isConnected()

    SettingsScaffold(title = "Phone Control", onBack = onBack, onClose = onClose) {

        // ── Messaging ─────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Messaging",
            footer = "You can always override per-message: \"text them on WhatsApp\" or \"send it as an SMS\".",
        ) {
            SettingsDropdownRow(
                title       = "Default channel",
                description = "Used when you don't specify how to send a message.",
                options     = channels,
                selected    = selectedChannel,
                label       = { it.second },
                onSelected  = { vm.setDefaultMsgChannel(it.first) },
            )
            SettingsRowDivider()
            SettingsValueRow(
                title       = "Notification access",
                value       = when {
                    notifGranted && notifConnected -> "Active"
                    notifGranted                  -> "Granted (listener offline)"
                    else                          -> "Not granted"
                },
                description = if (!notifGranted)
                    "Required to read and reply to messages by voice." else null,
            )
            if (!notifGranted) {
                SettingsRowDivider()
                SettingsActionRow(
                    title       = "Grant notification access",
                    description = "Opens the system notification listener settings",
                    actionLabel = "Open",
                    onAction    = {
                        context.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    },
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // ── App control ───────────────────────────────────────────────────────
        SettingsGroup(
            title  = "App control",
            footer = "Closing uses the Android HOME action — apps are sent to the background, not force-killed.",
        ) {
            SettingsToggleRow(
                title           = "App control enabled",
                description     = "Allow voice commands to open, close and navigate apps.",
                checked         = appControlEnabled,
                onCheckedChange = vm::setAppControlEnabled,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Use Accessibility Service",
                description     = "Enables 'go back' and 'close app' via global actions when available.",
                checked         = accessibilityControl,
                onCheckedChange = vm::setAllowAccessibilityAppControl,
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title           = "Allow app close commands",
                description     = "Let Jarvis go back to the home screen to exit a named or current app.",
                checked         = allowAppClose,
                onCheckedChange = vm::setAllowAppClose,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Contacts, Routines & Locations ────────────────────────────────────
        SettingsGroup(title = "Saved data") {
            SettingsActionRow(
                title       = "Contact aliases",
                description = "Nicknames like \"wifey\" or \"mum\" that route to a contact",
                actionLabel = "Manage",
                onAction    = onOpenContactAliases,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Saved locations",
                description = "Home, work and custom addresses for navigation",
                actionLabel = "Manage",
                onAction    = onOpenSavedLocations,
            )
            SettingsRowDivider()
            SettingsActionRow(
                title       = "Routines",
                description = "Saved sequences you can run by name",
                actionLabel = "Manage",
                onAction    = onOpenRoutines,
            )
        }
        Spacer(Modifier.height(8.dp))

        // ── Permissions ───────────────────────────────────────────────────────
        PermissionHealthCard(
            permissions = permissions,
            onFix = { perm -> PermissionUtils.openPermissionSettings(context, perm) },
        )
        Spacer(Modifier.height(8.dp))

        // ── Web search ────────────────────────────────────────────────────────
        SettingsGroup(
            title  = "Web search",
            footer = "DuckDuckGo is used by default (free, no key needed). " +
                     "Add a Brave key for richer results — free at search.brave.com/settings.",
        ) {
            SettingsTextFieldRow(
                title         = "Brave Search access key",
                description   = "Optional. Leave blank to use DuckDuckGo.",
                value         = braveKey,
                onValueChange = vm::setBraveSearchApiKey,
                placeholder   = "BSA…",
                isSecret      = true,
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}
