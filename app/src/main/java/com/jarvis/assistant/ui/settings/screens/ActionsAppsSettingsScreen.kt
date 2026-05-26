package com.jarvis.assistant.ui.settings.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jarvis.assistant.ui.SettingsViewModel
import com.jarvis.assistant.ui.settings.PermissionHealthCard
import com.jarvis.assistant.ui.settings.PermissionUtils
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsTextFieldRow

@Composable
internal fun ActionsAppsSettingsScreen(
    vm: SettingsViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context       = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val braveKey      by vm.braveSearchApiKey.collectAsStateWithLifecycle()

    // Build permission list on first composition, then re-check every time the
    // user returns from a system settings screen (ON_RESUME).
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

    SettingsScaffold(title = "Actions & Apps", onBack = onBack, onClose = onClose) {

        PermissionHealthCard(
            permissions = permissions,
            onFix = { perm -> PermissionUtils.openPermissionSettings(context, perm) },
        )

        SettingsGroup(
            title  = "Web search",
            footer = "DuckDuckGo is used by default (free, no access key needed). Add a Brave access key for " +
                     "richer results — get one free at search.brave.com/settings.",
        ) {
            SettingsTextFieldRow(
                title         = "Brave Search access key",
                description   = "Optional. Leave blank to fall back to DuckDuckGo.",
                value         = braveKey,
                onValueChange = vm::setBraveSearchApiKey,
                placeholder   = "BSA…",
                isSecret      = true,
            )
        }
    }
}
