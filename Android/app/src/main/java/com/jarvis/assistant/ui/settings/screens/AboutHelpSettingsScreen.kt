package com.jarvis.assistant.ui.settings.screens

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.jarvis.assistant.BuildConfig
import com.jarvis.assistant.ui.settings.SettingsGroup
import com.jarvis.assistant.ui.settings.SettingsInfoCard
import com.jarvis.assistant.ui.settings.SettingsRowDivider
import com.jarvis.assistant.ui.settings.SettingsScaffold
import com.jarvis.assistant.ui.settings.SettingsValueRow

/**
 * About & Help — single landing for plain-English help and app info.
 *
 *  - One-paragraph "what Jarvis does"
 *  - Plain-English explanation of Mac Integration (and what offline means)
 *  - App version and build mode
 *
 * Everything technical (gateway URLs, ports, transport modes, diagnostics
 * tools) lives behind Developer Mode → Developer Diagnostics, not here.
 */
@Composable
internal fun AboutHelpSettingsScreen(
    onBack: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val versionLabel = remember {
        runCatching {
            val pm   = context.packageManager
            val info = pm.getPackageInfo(context.packageName, 0)
            val mode = if (BuildConfig.DEBUG) "debug" else "release"
            "${info.versionName} (build ${info.longVersionCode}, $mode)"
        }.getOrDefault("unknown")
    }

    SettingsScaffold(title = "About & Help", onBack = onBack, onClose = onClose) {

        SettingsInfoCard(
            title = "Jarvis",
            body  = "Your personal voice assistant. Speak naturally — Jarvis listens " +
                    "for the wake word, understands what you mean, and acts. Your Mac " +
                    "powers memory and context; your phone handles voice, messaging " +
                    "and on-device actions.",
        )

        Spacer(Modifier.height(8.dp))

        SettingsGroup(
            title  = "Mac Integration",
            footer = "When your Mac is reachable, Jarvis uses it for long-term memory, " +
                     "project context and richer answers. When it isn't, Jarvis falls " +
                     "back to the on-device model so basic voice commands still work — " +
                     "you may notice shorter answers and no project context. " +
                     "Reconnection happens automatically as soon as your Mac is back.",
        ) {
            SettingsValueRow(
                title = "Set up in",
                value = "Settings → Mac Integration",
            )
        }

        Spacer(Modifier.height(8.dp))

        SettingsGroup(
            title  = "Tips",
            footer = "Wake Jarvis by saying \"Jarvis\". Pause briefly so it can hear " +
                     "you, then speak naturally — full sentences work better than " +
                     "single keywords. To stop a long answer, just start talking again.",
        ) {
            SettingsValueRow(title = "Wake word", value = "Jarvis")
        }

        Spacer(Modifier.height(8.dp))

        SettingsGroup(title = "App") {
            SettingsValueRow(title = "Version", value = versionLabel)
            SettingsRowDivider()
            SettingsValueRow(title = "Package", value = context.packageName)
        }

        Spacer(Modifier.height(24.dp))
    }
}
